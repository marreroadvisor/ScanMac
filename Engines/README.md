# Local image engines

Run `python3.12 Engines/install.py` once on macOS14+. Dependencies live in the ScanMac user Application Support directory. The installer downloads weights and dependencies; it never uploads documents. `worker.py` runs offline in a network-denied process for each request and deletes job files on completion/cancellation.

## Models

- Community Forensics: [OwensLab model](https://huggingface.co/OwensLab/commfor-model-384), [author implementation](https://github.com/s-jyeon/CommunityForensicsTrain). MIT; notice included. Architecture is instantiated locally with `pretrained=False` and weights loaded using safetensors; no remote Python is executed. Evaluation uses short-edge440, center384, ImageNet normalization and sigmoid, as in the author's pipeline.
- LaMa: [author repository](https://github.com/advimman/lama), Apache-2.0. [IOPaint distributor](https://github.com/Sanster/IOPaint/blob/main/iopaint/model/lama.py) publishes the TorchScript model and MD5. Both MD5 and pinned SHA-256 were verified. Only masked output pixels are composited; other pixels are preserved.

See `models.json` for immutable model revision, download URLs and SHA-256. Runtime hashes are checked before loading. Weight files are installed separately and excluded from source/app ZIPs.

## Forensic limits

The classifier score is not a calibrated probability. This integration does not certify image origin, validate digital signatures or identify a person. It is especially unreliable for scans, composites and novel generators. ELA and repeated SIFT-pattern groups provide evidence maps rather than a learned tamper verdict. Pixel comparisons require aligned originals; compression changes also count.

## Validation

`Tests/check_image_engines.py` checks a known gradient restoration (masked MAE95.52→2.05/255), exact preservation outside mask, ELA artifacts, repeated translated patches and reference-pixel differences. Optional classifier fixtures are supplied outside the repository. Seven public smoke examples yielded2 positive classifications among4 labeled-real inputs and0 negative classifications among3 labeled-synthetic inputs at threshold0.5. Labels were taken from the author's test folders plus two scikit-image natural photographs; this is a small, nonrepresentative, potentially overlapping set, not an independent accuracy estimate. The original numerical smoke-test report is not bundled; rerun the harness with independently labeled images to evaluate your use case. Public images are not redistributed here.
