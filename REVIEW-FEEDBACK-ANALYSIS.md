# RFC-HDFG-2026-003 — Review Feedback Analysis

**Date:** 2026-07-13
**Status:** Research complete; RFC revisions recommended but not yet applied
**Evidence base:** HDF5 source at `/home/brtnfld/work/hdf5.brtnfld` (develop-track
checkout, HEAD `820cf28a141`). All `file:line` references below are into that tree.

A reviewer raised six concerns about this RFC. Each was researched against the
actual library source. Summary:

| # | Concern | Verdict | RFC impact |
|---|---|---|---|
| F1 | One DCPL, two datasets, different blobs — programming model; blob-keyed-by-filter-ID design | **Valid critique** | §"H5Pappend_filter_blob" needs a per-dataset-association section; fix duplicate-filter-ID ambiguity |
| F2 | File format change unavoidable; risks immediate `H5Z_class4_t`; more weight on future work | **Confirmed** | Strengthen §"Relationship" timing note: callbacks must land in the same release as the format change |
| F3 | "Rank 0 writes + Bcast" parallel protocol too simple; global heap has no parallel access | **Confirmed — current §"Parallel I/O Write Protocol" is not viable as written** | Replace the resolved decision with a redesigned protocol (below); downgrade from Decision to Proposed |
| F4 | Reference-in-blob (Use Case B) is clunky; raw reference bytes are not recoverable on read | **Confirmed — and worse: no public encode API exists** | Reopen the Use Case B decision; the "no new API needed" conclusion does not hold |
| F5 | Maybe target 3.0 with a general file format change | **Viable either way** — minor release is technically sufficient; 3.0 grouping is a coordination argument | Add a release-targeting subsection; align with format-generation planning |
| F6 | A reference must be encoded into the bytestream before blob storage | **Confirmed** (same evidence as F4) | Folded into F4 |

---

## F1 — Per-dataset blobs from a shared DCPL

**Reviewer:** *"What would be the programming model if you want to use a single DCPL
for two different datasets that use the same filter, but you want different blobs
for each dataset? Would you just need two different DCPLs? Associating a blob with
a filter ID directly inside the pipeline seems like there might be better ways of
designing that."*

### Findings

1. **The DCPL is a template; each dataset takes a private deep copy.**
   `H5D__create` → `H5D__new` copies the caller's DCPL via
   `H5P_copy_plist(plist, false)` (`src/H5Dint.c:499`). Mutating the caller's
   DCPL after create never reaches an existing dataset. So "two different DCPLs"
   (or copy-then-tweak) is indeed the answer under the current design — and it is
   the established HDF5 idiom, not an anomaly:
   - External file list (`H5Pset_external`, `src/H5Pdcpl.c:2718-2774`) —
     per-dataset file names live in the DCPL; distinct config ⇒ distinct DCPL.
   - **Virtual dataset mappings** (`H5Pset_virtual`, `src/H5Pdcpl.c:2111-2308`) —
     the strongest precedent: inherently per-dataset source-file/dataset/selection
     mappings are stored inside the DCPL layout property, one DCPL per VDS.
   - `h5repack` itself uses copy-then-tweak: `H5Pcopy(dcpl_in)`
     (`tools/src/h5repack/h5repack_copy.c:910`) then adjusts the pipeline.

2. **But a large blob makes the template model expensive.** The pipeline property
   is deep-copied on every `H5Pcopy` *and* every `H5Dcreate` (the `cd_values`
   deep-copy logic in `H5Z_append`, `src/H5Z.c:1252-1269`, mirrors what the copy
   path does). A multi-MB blob stored in the pipeline property gets duplicated
   on each of those operations. This is a real cost argument the RFC currently
   ignores.

3. **Filter ID is not a unique key within a pipeline.** `H5Z_append`
   (`src/H5Z.c:1188-1275`) appends unconditionally — duplicate filter IDs in one
   pipeline are legal. `H5Z_modify` (`src/H5Z.c:1138-1140`) and
   `H5Z_filter_in_pline` (`src/H5Z.c:1632-1653`) resolve an ID to the **first
   match**. A blob "associated with a filter ID" inherits this first-match
   ambiguity: two entries of the same filter with different blobs cannot be
   expressed. The reviewer's instinct that ID-keyed association is the wrong
   primitive is supported by the code.

4. **The existing "same template DCPL, per-dataset customization" hook is
   `set_local`.** `H5Z_set_local` runs against the dataset's *private copy*
   (`src/H5Dint.c:1281` passes `new_dset->shared->dcpl_id`, the copy from line
   499), and filters like shuffle (`src/H5Zshuffle.c:84`) and szip
   (`src/H5Zszip.c:232`) already rewrite their own pipeline entry per dataset via
   `H5P_modify_filter`. This is the proven mechanism by which one DCPL yields
   per-dataset pipeline content — but it is filter-author-driven, not
   caller-driven.

### Recommended RFC changes

- **Key the blob by pipeline index, not filter ID** — internally the blob should
  attach to a specific `H5Z_filter_info_t` entry (it already does), and any
  public accessor should address entries by index like `H5Pget_filter2` does,
  never by ID. `H5Pappend_filter_blob` is actually fine here (it *appends* a new
  entry, so the association is positional at creation) — but the RFC text saying
  the blob is "associated with filter `id`" should be corrected to "associated
  with the pipeline entry created by this call."
- **Add a "Programming model: per-dataset blobs" subsection** stating explicitly:
  the DCPL-template answer is one DCPL per distinct blob (copy-then-tweak; VDS
  and EFL precedent), and noting the deep-copy cost for large blobs.
- **Evaluate two alternatives** in an alternatives-considered subsection:
  (a) a create-time argument (precedent: `type_id`/`space_id` are per-dataset
  arguments to `H5Dcreate`, `src/H5Dint.c:1195`) — keeps the template pure but
  changes signature conventions; (b) a `set_local`-style per-dataset override
  hook so a filter can compute/replace its blob per dataset from the dataset's
  type/space. A copy-on-write or refcounted blob buffer inside the pipeline
  property would address the deep-copy cost without changing the model.

---

## F2 — File format change and `H5Z_class4_t` timing

**Reviewer:** *"The blob callbacks are going to require a file format change since
we have to store the global heap ID in the pipeline message. That also seems like
it's going to immediately require a v4 of the filter structure... unless we can get
the blob callbacks correct the first time, there will need to be a v4 filter
structure and the callbacks won't be functional until a file format change most
likely."*

### Findings

1. **Format change confirmed unavoidable for first-class support.** The current
   pipeline message record (`H5O__pline_encode`, `src/H5Opline.c:279-349`) has no
   field that could hold a global-heap locator — every field is a small fixed
   integer or the inline name/`cd_values`. The `H5HG_t` locator
   (`{haddr_t addr; size_t idx;}`, `src/H5HGprivate.h:20-23`) has nowhere to
   live. A new pipeline message version is required. The only genuine
   no-format-change fallback is a reserved-attribute convention (the dimension-
   scales model: `DIMENSION_LIST`/`REFERENCE_LIST` attributes, `hl/src/H5DS.c:59-105`)
   — workable but second-class: no structural binding to a pipeline entry, no
   copy/delete coupling (the `H5O__pline_copy_file` path at `src/H5Opline.c:610`
   would not carry it), tool invisibility, and user-attribute collision risk.
   This matches the reviewer's "there might be some hacks... I doubt it would be
   pretty."

2. **The struct-versioning risk is real and cuts the way the reviewer says.**
   In-tree today: `H5Z_class2_t` is the latest, `H5Z_CLASS_T_VERS (1)`
   (`src/H5Zdevelop.h:31,162-171`); `H5Z_class3_t` exists only in
   RFC-HDFG-2026-001. Two failure modes: (a) if 001's class3 ships in a release
   *before* the blob format change lands, the blob callbacks need a class4;
   (b) even if the callbacks are added to class3 speculatively, they are dead
   weight — non-functional — until the pipeline-message version exists, and if
   prototype experience then forces a signature change (see F3/F4 — both
   sections below *do* force changes), a class4 is needed anyway. Speculatively
   shipping unproven callback signatures is exactly how the earlier
   "reserved `void*` fields" mistake happened (dropped in 001 commit `db64309`).

### Recommended RFC changes

- Replace the current "if 001 has shipped / hasn't shipped" timing note with a
  stronger position: **the blob callbacks and the pipeline-message format version
  must land in the same release**, and class3 should not carry the callbacks in
  any release that lacks the format version. Practically this means either
  (a) hold the callbacks out of class3 until this RFC's format work is scheduled
  into a release, or (b) schedule both into the same format-generation release
  (see F5).
- Add the reserved-attribute fallback to an alternatives-considered section with
  the tradeoffs above, so the "why a format change" question is answered in the
  document rather than in review threads.

---

## F3 — Parallel I/O: "rank 0 writes + broadcast" is not viable as written

**Reviewer:** *"VL and region ref. writing is specifically disabled in parallel due
to not supporting parallel access to the global heap, so I'm fairly confident it's
currently a bit more complicated than just 'have rank 0 do the writing'."*

### Findings — the reviewer is right, and the RFC's resolved decision is wrong

1. **The VL/region-ref parallel ban exists and says why**
   (`src/H5Dio.c:590-598`):
   ```c
   /* If MPI based VFD is used, no VL or region reference datatype support yet. */
   /* This is because they use the global heap in the file and we don't */
   /* support parallel access of that yet */
   if (H5T_is_vl_storage(dset_info[i].type_info.mem_type) > 0)
       HGOTO_ERROR(..., "Parallel IO does not support writing VL or region reference datatypes yet");
   ```

2. **Rank-0-only `H5HG_insert` violates the parallel metadata-cache coherency
   invariant.** The invariant is stated verbatim in `src/H5ACmpio.c:1103-1106`:
   *"all operations writing metadata must be collective. Thus all metadata caches
   see the same sequence of operations, and therefore the same dirty data
   creation."* `H5HG_insert` performs three cache-visible actions: file-space
   allocation (`H5MF_alloc`, `src/H5HG.c:139`), a cache-entry insert
   (`H5AC_insert_entry`, `src/H5HG.c:188`), and a dirty-on-unprotect
   (`H5AC__DIRTIED_FLAG`, `src/H5HG.c:520,527`). The sync-point trigger counter
   `dirty_bytes` is advanced on **every** rank when an entry is inserted/dirtied
   (`src/H5ACmpio.c:931`, `:744`) precisely because every rank is assumed to
   perform the same insert. If only rank 0 inserts, the ranks disagree on when
   to enter the collective sync point (`src/H5ACmpio.c:1985-1988`) and the
   candidate-list distribution assumes entries exist identically in all caches
   (`src/H5ACmpio.c:1536-1540`: the dirty-entry list *"must be identical across
   all processes"*) → deadlock or corruption.

3. **The "rank 0 + Bcast" precedent the RFC cited does not apply.** The existing
   patterns (`src/H5Fsuper.c:363-375` superblock-signature search;
   `src/H5FDmpio.c:1389,2232,3180` read-and-broadcast) are **read-side and
   raw/VFD-level**. No code today broadcasts a *newly created dirty metadata
   entry's* address, and no machinery exists to inject a metadata entry into
   ranks >0's caches or reconcile their `dirty_bytes`.

4. **The correct shape is the opposite of the RFC's protocol.** In the PHDF5
   model, `H5Dcreate` metadata is produced **redundantly-but-identically on every
   rank**. A blob written at `H5Dcreate` time from a DCPL that is (already,
   by rule) identical on all ranks satisfies exactly the conditions the model
   needs: **all ranks call the identical `H5HG_insert` with identical bytes**;
   each rank computes the same `H5MF_alloc` address from identical free-space
   state, each inserts the identical dirty entry, and every rank arrives at the
   same locator with **no broadcast at all**. (This is also why the H5Dwrite-time
   VL ban does not contradict this: VL element data differs per rank and flows
   through independent I/O paths; the blob is create-time-collective with
   rank-identical content.)

   Caveats that keep this "proposed, pending validation" rather than "resolved":
   the determinism argument leans on the invariant that all prior metadata
   operations were identical (true by rule, but any pre-existing rank divergence
   turns into silent address divergence here — worth an `MPI_Bcast`-based debug
   assertion); paged allocation/free-space-manager settings and the
   `H5FD_MEM_GHEAP` allocation type need checking; and this needs prototype
   validation with the parallel metadata-cache owners.

### Recommended RFC changes

- **Delete the rank-0-write-plus-broadcast protocol** (current
  §"Parallel I/O Write Protocol", including its code listing) and replace it with
  the collective-identical-insert protocol above, explicitly grounded in the
  redundant-metadata model (`src/H5ACmpio.c` invariants) and explicitly
  contrasted with the H5Dwrite-time VL ban.
- Downgrade the section from **Decision** to **Proposed decision (pending
  prototype validation)** and add the caveats list. This is the one place the
  RFC currently states something the library's own design documentation
  contradicts.
- Custom `write_blob` callbacks in parallel inherit the same requirement:
  either they must behave identically on all ranks, or parallel use of
  custom-callback filters must be restricted. Add a normative statement.

---

## F4 — Use Case B: storing a dataset reference in the blob is broken as designed

**Reviewer:** *"Before the blob object is stored, a reference object would need to
be encoded into the bytestream. Without that, I don't think you'd be able to
recover the reference on read_blob just from storing the runtime bytes."* Plus:
extra global-heap overhead, temporary reference objects, no partial I/O on the
mask dataset.

### Findings — confirmed, and stronger than the reviewer stated

1. **Raw `H5R_ref_t` bytes are not persistable.** The public 64-byte blob
   (`H5R_REF_BUF_SIZE 64`, `src/H5Rpublic.h:38,97-103`) actually holds
   `H5R_ref_priv_t` (`src/H5Rpkg.h:70-81`) containing a **cached `hid_t loc_id`**
   (process-local, stale after reopen), an `app_ref` bookkeeping flag, and —
   inside the union — **raw heap pointers** (`char *filename`, `H5S_t *space`,
   `char *name`, `src/H5Rpkg.h:54,60,66`). Memcpy'd to disk and read back in a
   new session, a stale non-invalid `loc_id` is passed straight into
   `H5CX_set_apl`/VOL setup by `H5Ropen_object` (`src/H5R.c:513-529`) —
   undefined behavior — and any path touching the pointers dereferences garbage.

2. **The library itself never stores the runtime form.** When a reference is
   written into a dataset/attribute, the datatype conversion calls
   `H5R__encode` (`src/H5Tref.c:621`) producing a versioned, self-contained
   stream (2-byte header + length-prefixed token + optional
   filename/selection/name, `src/H5Rint.c:856-944`), and stores it via the
   blob/global-heap layer (`H5VL_blob_put`, `src/H5Tref.c:1014`). On read,
   `H5R__decode` **resets `loc_id` to `H5I_INVALID_HID`** (`src/H5Rint.c:1033-1034`)
   and the library re-attaches the *currently open* file
   (`H5R__set_loc_id`, `src/H5Tref.c:724-733`). Recovery on read requires that
   re-attachment step; `read_blob`'s `file_id` would serve that role, but only
   if the bytes were properly encoded first.

3. **There is no public encode API for a filter author to call.**
   `H5R__encode`/`H5R__decode` are package-private (`src/H5Rpkg.h:112,114`);
   grep confirms no `H5Rencode`/`H5Rdecode` in any public header. So the RFC's
   current instruction — the filter "dereferences it inside its own `read_blob`
   implementation" after storing the reference in the blob — **cannot be
   implemented correctly by a plugin today at all.** The Use Case B resolution
   ("no new public API surface needed") is wrong on this point.

4. **Reviewer's secondary points hold too:** a reference stored via the proper
   datatype path costs an additional global-heap object; the encode/decode dance
   involves temporary reference objects; and reading the mask inside
   `read_blob`/open-time means the full mask is materialized at `H5Dopen` with
   no partial-I/O option (as currently designed).

### Recommended RFC changes

- **Reopen the Use Case B decision.** Replace "store the reference in the blob"
  with, in order of preference:
  1. **Store a path string** (the mask dataset's absolute name) in the blob.
     Filter calls `H5Dopen2(file_id, path, ...)` inside `read_blob` (or lazily).
     No reference machinery, no extra heap object, trivially portable across
     `h5repack` (both datasets travel together). Limitation: breaks if the mask
     is renamed/moved — document it.
  2. **Public `H5Rencode`/`H5Rdecode`** as a named prerequisite (new public API,
     separate small RFC) if true reference semantics (rename-proof tokens) are
     required.
- **Address partial I/O**: note that a filter may open the mask dataset at
  `read_blob` time but defer actual reads to per-chunk `H5Dread` calls with
  hyperslab selections from within the filter callback (the `H5Z_func2_t`
  chunk coordinates from RFC-HDFG-2026-001 make the needed region computable) —
  or state explicitly that full-mask materialization at open is accepted for
  v1 of the feature.

---

## F5 — Release targeting: minor release vs. 3.0

**Reviewer:** *"Maybe it would make things easier to target a 3.0 with a file
format change in general for this work? ... I just don't think we need to
introduce hacky type stuff just to avoid a major release. I can't remember if any
of the DE Shaw work needed a major release."*

### Findings

1. **The libver-bounds mechanism makes a minor release technically sufficient.**
   The standard pattern: add `H5O_PLINE_VERSION_3`, add a row to
   `H5O_pline_ver_bounds[]` (`src/H5Opline.c:85-92`), and version selection
   (`MAX(low_bound)` + high-bound rejection, `src/H5Opline.c:711-714`) does the
   rest. Precedent: layout message v4 (virtual datasets) shipped exactly this
   way in 1.10; datatype v3, fill v3, link-info, etc. all follow the same
   pattern. Old libraries fail cleanly with *"bad version number for filter
   pipeline message"* (`src/H5Opline.c:132-133`).

2. **A format-generation slot already exists and is empty.**
   `H5F_LIBVER_V200` exists (`src/H5Fpublic.h:186`, aliased by `LATEST`), and
   notably **no existing message bumps its version at the V200 row** (pline maps
   V200→V2, `src/H5Opline.c:91`; fill likewise, `src/H5Ofill.c:156`). So there
   is a defined-but-undifferentiated format generation waiting; introducing the
   new pline version at a dedicated format bound (V200 or the next one, i.e.,
   the "3.0" bound) keeps the which-library-reads-what contract clean, which is
   the concrete (coordination, not technical) advantage of the reviewer's
   "target 3.0" suggestion.

3. **DE Shaw precedent (inconclusive, for the record):** the public D. E. Shaw
   HDF5 work is [Versioned HDF5](https://www.deshaw.com/library/desco-quansight-introducing-versioned-hdf5)
   ([design](https://labs.quansight.org/blog/design-of-the-versioned-hdf5-library)) —
   a pure-Python layer over h5py requiring **no** library format change or
   release at all. The in-library format-change work in flight (sparse data /
   structured chunks, [HDF Group/Lifeboat](https://www.hdfgroup.org/wp-content/uploads/2023/08/Sparse-HDF5-2023-08-17.pdf),
   [discussion #3257](https://github.com/HDFGroup/hdf5/discussions/3257)) does
   involve file-format and API changes and is being staged through the same
   versioned-message/libver mechanism. Neither required a "major release" in
   the semver sense; format generations and release majors are coupled by
   project policy, not by the version-bounds machinery.

### Recommended RFC changes

- Add a short "Release and format-generation targeting" subsection: state that
  the mechanism is libver-bounds-gated either way; that this RFC has no
  technical dependency on a major release; and that the pipeline-message
  version row should be introduced at whichever format bound the 3.0 planning
  designates (with F2's constraint that struct callbacks and format version
  ship together). Both this RFC and RFC-HDFG-2026-001's future typed-cd_values
  extension should target the same bound to avoid two consecutive format bumps
  to the same message.

---

## Consolidated revision checklist for the RFC

1. §Parallel I/O Write Protocol — **replace entirely** (F3): collective
   identical insert, no broadcast; downgrade to proposed-pending-validation;
   add custom-callback parallel requirements.
2. §Use Case B — **reopen decision** (F4): path-string primary design, public
   `H5Rencode`/`H5Rdecode` as alternative prerequisite; partial-I/O note.
3. §H5Pappend_filter_blob — clarify blob associates with the *pipeline entry*,
   not the filter ID; add per-dataset programming-model subsection and
   alternatives (F1); note deep-copy cost and possible refcounted buffer.
4. §Relationship to RFC-HDFG-2026-001 — same-release constraint for callbacks
   + format version; no speculative callbacks in class3 (F2).
5. New §Release targeting (F5).
6. §On-Disk Format — add the reserved-attribute fallback to
   alternatives-considered, with tradeoffs (F2).

## Sources

- HDF5 source: `/home/brtnfld/work/hdf5.brtnfld` @ `820cf28a141` (all file:line cites above)
- [Versioned HDF5 — The D. E. Shaw Group](https://www.deshaw.com/library/desco-quansight-introducing-versioned-hdf5)
- [Design of the Versioned HDF5 Library — Quansight Labs](https://labs.quansight.org/blog/design-of-the-versioned-hdf5-library)
- [Supporting Sparse Data in HDF5 (2023)](https://www.hdfgroup.org/wp-content/uploads/2023/08/Sparse-HDF5-2023-08-17.pdf)
- [HDFGroup/hdf5 discussion #3257 — sparse data & enhanced VL support](https://github.com/HDFGroup/hdf5/discussions/3257)
