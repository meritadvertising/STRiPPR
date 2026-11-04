# Attribution and dependencies

Copyright (c) 2026 Merit Advertising Corp. and STRiPPR contributors, to the extent
copyrightable rights exist. STRiPPR was created for LaZ at Merit Advertising Corp.
with his ChatGPT dot, **Dumdum**, which generated and implemented the app under
LaZ's direction. This credit describes AI assistance, not human authorship.
Its wordmark and
dissolving-R icon were generated with ChatGPT and are included with the project
under the MIT license, to the extent applicable rights exist. Image provenance
metadata may identify that generation. No exclusive rights in AI output are
promised.

The application links Apple's system frameworks and Swift runtime. These are
provided by macOS and are not redistributed in this repository. Package.swift
declares no external package dependencies. The app does not bundle FFmpeg,
ExifTool, VLC, TagLib, or a metadata-removal library.

Optional integration-test scripts use separately installed FFmpeg/FFprobe and,
for the VLC-specific regression check, the user's separately installed VLC.
Those programs are not distributed here. Their own licenses apply to them.
Small playable test fixtures are generated from synthetic test patterns and
tones; they contain no supplied personal media.

Metadata names and format behavior were checked against the primary format
references linked in docs/METADATA-SUPPORT.md. Those references are not vendored
source code or a license grant for third-party projects.

The MIT license applies to the original project source, documentation, and
included artwork as described above. It does not relicense Apple software,
optional external test tools, their trademarks, or linked third-party material.
