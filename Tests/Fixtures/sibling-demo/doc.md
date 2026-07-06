# Sibling folder image

This document lives in its own folder and references an image in a
**sibling subfolder** (`assets/pixel.png`) — the J3 relative-link/image
scenario `FolderAccessStore` exists to fix (PLAN §8 risk #5). Headless
snapshot proof that the resolution path (`ImageBlockView.resolvedURL` →
`assets/` relative to `doc.md`'s directory) renders correctly once the
containing folder is readable.

![a single red pixel](assets/pixel.png)

Rendering the image above (rather than the "Image unavailable" or "Allow
Access" placeholder) proves the sibling-folder resolution + render pipeline
works end-to-end.
