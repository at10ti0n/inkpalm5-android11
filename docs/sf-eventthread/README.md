# SurfaceFlinger: incident-one binary checkpoint

The supplied binary narrows what to inspect on recurrence, but does not establish a root cause. No device changes were made. Keep the standby-image patch offline and preserve the current observation configuration.

## Exact input and reproducibility

Input: `incident1-2026-09-17/libsurfaceflinger.so` from the supplied evidence bundle.

- SHA-256: `4bf68ec57473f69f22f6a307566efa354edccff12a57940474381996c874bf71`
- Build ID: `5ffeeeeef796a40caaf474d3b30af5f2`
- Architecture: ARM32; EventThread code is Thumb, the sampled PLT stub is ARM.

The ELF includes compressed `.gnu_debugdata`. Decompressing it recovers the EventThread constructor's thread-proxy symbol at Thumb symbol value `0x9ff99`, size 2200 bytes. Its code begins at `0x9ff98`; several EventThread operations are inlined there.

Run locally with Python, capstone and pyelftools:

```sh
python3 inspect_sf.py /path/to/libsurfaceflinger.so > inspection.txt
```

The script refuses any other input hash. It reads the ELF, extracts symbols, resolves the sampled relocation, and disassembles two manually established code spans, omitting literal pools. `inspection.txt` records the dependency versions and actual output. The input vendor library is not redistributed in this package.

## What the sampled PC actually identifies

Incident one's reported relative PC `0x1505e8` is the final instruction of this PLT entry:

```text
1505e0  add ip, pc, #0
1505e4  add ip, ip, #0x13000
1505e8  ldr pc, [ip, #0x348]!
```

The effective GOT address is `0x163930`. Its relocation names `android::RefBase::decStrong(void const*) const`. The stub itself has no loop: it jumps through the GOT. A sampled PC here does not prove that reference counting is defective, identify the surrounding loop, or establish mutex ownership.

Four direct calls in the recovered thread proxy reach this stub. The roles below are interpretations of the surrounding compiled control flow, cross-checked against the comparable LineageOS Android 11 EventThread source; the addresses and return values are direct binary observations.

| Call instruction | Expected ELF-relative LR at stub | Interpreted path |
| --- | --- | --- |
| `0xa04e0` | `0xa04e5` | Old consumer-vector storage cleanup during reallocation |
| `0xa050c` | `0xa0511` | Temporary strong-reference release during connection scanning |
| `0xa0674` | `0xa0679` | Consumer-vector clear following dispatch |
| `0xa07be` | `0xa07c3` | Consumer-vector destruction on thread exit |

The low bit in LR denotes a Thumb return. For a normal intact direct call, the stub has not changed LR, so a register capture at this precise PC can distinguish these call sites. These are the four calls in this function, not all callers in SurfaceFlinger. Corrupt control flow or a capture elsewhere requires separate analysis.

Use the mappings from the same incident to calculate the ELF load bias; do not subtract an arbitrary mapping start or reuse the healthy baseline's addresses. Normalize the runtime LR with that load bias and account for its Thumb bit. The old incident-one backtrace lacks the required registers and mappings, so its unknown caller address cannot safely be resolved this way.

## Other useful boundaries

The compiled dispatch path advances after the `-EAGAIN` branch; it does not visibly retry that same send in an immediate EAGAIN loop. The function also contains condition-variable waits. These observations weaken those particular simple explanations, but do not show that every runtime path reaches a wait or that the loop's data structures are intact.

Source comparison: [LineageOS lineage-18.1 EventThread.cpp](https://github.com/LineageOS/android_frameworks_native/blob/lineage-18.1/services/surfaceflinger/Scheduler/EventThread.cpp). This is a comparison implementation, not a verified exact source revision for the supplied ELF. The reproduction script depends on the ELF rather than that mutable branch.

## What to do next

1. Keep the existing watcher and rolled-back framework configuration stable. The offline standby patch has no demonstrated connection to this failure.
2. On a recurrence, try ADB before forcing a reboot. Preserve the complete timestamped capture directory, including partial outputs and exit statuses. The profile, register-bearing tombstone, and process mappings are the decisive existing artifacts.
3. Identify the hot thread in the profile and compare it with the tombstone thread. If it is caught at this PLT instruction again, use the LR table above. If it is elsewhere, analyze that instruction and its surrounding loop instead of forcing the previous explanation onto it.
4. Resolve samples against exact matching libraries/build IDs. A tombstone is a later snapshot than the profile, so disagreement can reflect a state change rather than bad data.
5. Propose a narrow fix only after identifying a repeatable failing path, with a test that distinguishes it from ordinary dispatch and reference cleanup.

No additional watcher change or speculative kernel patch follows from this analysis. Existing captures cannot demonstrate the internals of incident two or prove it is the same failure as incident one.

One correction to the earlier reasoning: a runnable userspace thread can be frozen during system suspend. High CPU use alone does not prove that suspend is impossible; suspend events, wake sources and their timing are needed. The historical awake percentages therefore do not justify a precise onset or a claim that the entire night was healthy.
