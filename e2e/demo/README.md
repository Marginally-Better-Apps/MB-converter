# Demo flows

Maestro flows used for the **final** headed Simulator demo recording only.

CI should run `e2e/` and **exclude** this folder.

## Full flow (`full-flow.yaml`)

Drives Home → Try sample file → import detail → convert config → Convert →
processing → result. Uses `fixtures/media/tiny.mp4` (real tiny H.264/AAC MP4).

Waits up to ~3 minutes for encode on Simulator (usually much faster for tiny.mp4).

Requires a **Custom Dev Client** build with FFmpeg frameworks downloaded — Expo Go
will not run the encode step.

Record with:

```sh
./scripts/record-demo.sh e2e/demo/full-flow.yaml /tmp/mb-demo.mp4
```

CI navigation coverage (no encode) lives in `e2e/convert-nav.yaml`.
