# Demo flows

Maestro flows used for the **final** headed Simulator demo recording only.

CI should run `e2e/` and **exclude** this folder.

## Current skeleton (`full-flow.yaml`)

Drives Home → Try sample file → import detail → convert config (format + target presets).
Does **not** start encode yet by default — uncomment processing steps when
recording the final demo (`fixtures/media/tiny.mp4` is a real tiny H.264 MP4).

When ready for the full encode demo (Epic 5), uncomment the convert → processing → result steps in `full-flow.yaml` and record with:

```sh
./scripts/record-demo.sh e2e/demo/full-flow.yaml /tmp/mb-demo.mp4
```

CI navigation coverage lives in `e2e/convert-nav.yaml`.
