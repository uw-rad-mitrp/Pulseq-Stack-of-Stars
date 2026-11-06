# Pulseq Stack of Stars

A 3D radial stack-of-stars dual-echo gradient-echo sequence for two-point Dixon fat-water
imaging, written in MATLAB with [Pulseq](https://github.com/pulseq/pulseq). It is a
slab-selective, RF-spoiled GRE with Cartesian kz partition encoding (with partial Fourier),
in-plane radial spokes and two bipolar echoes per TR. The writer produces a Pulseq `.seq`
file and converts it for GE scanners through
[pulseg](https://github.com/HarmonizedMRI/pulseg) and
[pge2](https://github.com/HarmonizedMRI/pge2) (Pulseq -> pulseg -> pge2). The sequence was
run on a GE SIGNA Premier 3T and a GE SIGNA PET/MR 3T.

## Contents

| File | Purpose |
| --- | --- |
| `sequence/StackOfStars_newRotv3.m` | Sequence writer. Builds the design for each scanner and writes `.seq`, `.mat` and `.pge` files next to itself. |
| `sequence/STARS_v3.seq`, `sequence/STARS_v3.pge` | Built sequence for the GE SIGNA Premier, written by `StackOfStars_newRotv3.m`. |
| `sequence/STARS_v3_petmr.seq`, `sequence/STARS_v3_petmr.pge` | Built sequence for the GE SIGNA PET/MR, written by `StackOfStars_newRotv3.m`. |
| `geScannerOpts.m` | Per-scanner pge2 settings (`pge2.opts`, PNS weights, file suffix, header slew option). |
| `matlab/startup_pulseq.m` | Puts the pinned Pulseq / pulseg / pge2 toolboxes from `libs/` on the MATLAB path. |
| `setup.sh` | Clones the pinned toolchain into `libs/`. |
| `versions.lock` | Repositories and commits fetched by `setup.sh`. |
| `LICENSE` | MIT license. |

## Requirements

- MATLAB. The writer calls `wrapToPi`, which is not part of base MATLAB; it ships with
  toolboxes such as the Mapping Toolbox.
- Pulseq v1.5.1, pulseg and pge2 at the commits pinned in `versions.lock`, fetched by
  `./setup.sh` into `libs/`.
- git (used by `setup.sh`).
- To scan: the pge2 interpreter on the GE scanner, see
  [HarmonizedMRI/pge2](https://github.com/HarmonizedMRI/pge2).

## Quick start

```bash
cd Pulseq-Stack-of-Stars
./setup.sh
```

Then, in MATLAB:

```matlab
cd sequence
StackOfStars_newRotv3
```

The writer finds `matlab/startup_pulseq.m` by walking up from its own folder and adds the
repository root to the path for `geScannerOpts.m`, so it can also be run from any folder
with `run('<repo>/sequence/StackOfStars_newRotv3.m')`. It starts with `clear; clc; close all;`,
so it clears the MATLAB workspace.

Options are variables near the top of the script:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCANNERS` | `["premier" "petmr"]` | Scanners to build for. Each value selects the design limits in the script and is passed to `geScannerOpts` (`"premier"` or `"petmr"`). |
| `WRITE_PGE` | `true` | Also convert to `.pge` (and save the `.mat`). |
| `DOVALIDATE` | `true` | Run `pge2.validate` to compare the pulseg sequence with the `.seq` (slow). |

Sequence parameters (FOV, matrix, flip angle, TE, ordering, etc.) are set in the
"Sequence parameters" section; per-scanner gradient, slew, TR and spoiler limits are set in
the `switch scanner` block.

Outputs are written to `sequence/`, overwriting the files included in the repository:

- `STARS_v3.seq`, `STARS_v3.mat`, `STARS_v3.pge` for `"premier"`
- `STARS_v3_petmr.seq`, `STARS_v3_petmr.mat`, `STARS_v3_petmr.pge` for `"petmr"`

The `.mat` holds `psq`, `params`, `pislquant` and `smaxActual` (the real peak slew in G/cm/ms).
The writer prints a summary of TE, TR, scan time, slab and spoke settings for each scanner.

## Notes

Sequence parameters as set in the writer (the same for both scanners unless noted):

| Parameter | Value |
| --- | --- |
| In-plane FOV / matrix | 500 mm, 256 x 256 |
| Readout | 1.5x oversampled: 384 samples, 2 us dwell (768 us flat top) |
| Echoes | 2 per TR, bipolar readout; dTE = readout gradient duration (0.984 ms in the built files) |
| TE1 | 1.1 ms requested; the writer runs at the minimum if this is not reachable (about 1.23 ms in the built files) |
| TR | 3.9 ms (Premier), 5.312 ms (PET/MR) |
| Flip angle | 12 deg |
| Excitation | Slab-selective sinc, 0.5 ms, time-bandwidth product 8 |
| Slab | 30 partitions x 3 mm = 90 mm |
| kz encoding | 8% slab oversampling: 32 encoded partitions (96 mm z FOV); partial Fourier (`pfkz_ratio = 0.3`) skips the first 10 kz lines, so 22 partitions are played |
| Spokes | 403 (Nx x pi/2 = 402, rounded up to an odd number so the angles do not repeat) |
| Spoke ordering | Linear, with a stride of 4 x 360/403 = 3.57 deg (4 passes over 360 deg, 403 distinct angles); a golden-angle option is available (`angle_flag = 1`) |
| Loop order | Spokes in the outer loop, kz partitions in the inner loop |
| Spoiling | RF spoiling (117 deg increment); z spoiler of 2 cycles per partition, with kz rewound in the same gradient |
| Gradient limits | Premier: 50 mT/m, 150 T/m/s. PET/MR: 31.35 mT/m, 150 T/m/s, z spoiler capped at 10 mT/m |
| Scan time | 34.6 s (Premier), 47.1 s (PET/MR) for the built files |

- Spokes are rotated with the Pulseq rotation extension. The z encode and spoiler gradients
  use 70% of the slew limit to reduce PNS.
- The `.seq` files record `FOV` (with the encoded z FOV), `SlabThickness`,
  `SlabOversampling`, `PartitionsEncoded`, `PartitionsPlayed` and `Scanner` in their
  `[DEFINITIONS]` section.
- PET/MR: the longer TR and the 10 mT/m z spoiler cap were chosen for the console's gradient
  heating check (predicted about 95% of the limit).
- `geScannerOpts.m` sets `zeroSlew = true` for both scanners, so the `.pge` header maxSlew is
  written as 0 and the interpreter's header peak-slew check does not reject the file; desktop
  `pge2.check` still enforces the slew limit in `geScannerOpts.m`. The PET/MR design limit
  is 150 T/m/s, above the PET/MR console limit of 11.9565 G/cm/ms (about 120 T/m/s). PNS weights are `[1 1 1]`
  for the Premier and `[0.1 0.1 0.1]` for the PET/MR. Review these settings against your
  site's safety requirements before scanning.
- Reconstruction is not included in this repository.

## Citation

If you use this code, please cite:

- Wang JH, Pirasteh A, McMillan AB. Improvement in fat-water separation using modeled
  gradient impulse response with two-point Dixon radial imaging. Proc ISMRM 2024; #1906.
- Wang J, Erbil O, Dillinger H, Schmitter S, Wieben O, Pirasteh A, McMillan AB. Development
  and validation of gradient impulse response function measurements on an open-source
  platform. ISMRM 2026, Cape Town; #567-02-001.

## License

MIT, see [LICENSE](LICENSE).
