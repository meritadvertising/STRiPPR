# Metadata coverage and preservation

STRiPPR edits a finite allowlist of descriptive metadata in MP4/MOV metadata containers and AVI INFO lists. It does not remux or re-encode. Each edit preserves the original byte length, becomes a padding atom/chunk, and clears its former payload. The cleaner compares the entire result against the source plus the exact planned edits before publishing a new copy.

## Added descriptive coverage

In addition to title, artist, album, comments, genre, dates, copyright, lyrics, location, and existing sort fields:

- Catalog organization: track/disc numbers (`trkn`, `disk`, `©trk`), compilation (`cpil`), tempo (`tmpo`), rating/advisory (`rate`, `rtng`). These are metadata values, not track tables or media timestamps.
- Television and podcasts: network, season, episode number, podcast flag/URL/episode identifier (`tvnn`, `tvsn`, `tves`, `pcst`, `purl`, `egid`), and sort-show (`sosn`).
- Credits: author/composer aliases, publisher, director, producer, arranger, art director, conductor, soloist, sound engineer, executive producer, original artist, performers, information, liner notes, phonogram rights, and acknowledgements.
- Musical work organization: work/movement names and numbers/count, display-work flag, and work subtitle. These do not refer to media samples or playback edit lists.
- Exact `mdta` descriptive text keys for the same categories, plus documented QuickTime location names/notes/role/date/accuracy. Language, orientation, color, paired-media identity and other unlisted keys are retained.
- Strict iTunes freeform triplets: exactly one `mean`, `name`, and `data`, zero name/namespace version flags, a UTF-8 or UTF-16 text `data` type, and namespace exactly `com.apple.iTunes`. Only explicit descriptive labels, credits, work/catalog identifiers, and known MusicBrainz names are removable. No wildcard or prefix grants removal.

The code's dictionaries are the authoritative complete list. Unknown fields and namespaces remain visible as retained metadata.

## Deliberately retained

Encoder/software container fields are retained by default. Turning off **Keep encoder info** makes only known container fields (`©too`, `©enc`, `©swr`, recognized `mdta` software/encoder keys, AVI `ISFT`) removable. Their absence is verified with that same policy. Encoder identifiers inside compressed packets remain because removing them would change payload bytes.

Always retained: `Encoding Params`; `iTunSMPB` encoder delay and padding; `pgap`/gapless information; `iTunNORM`, ReplayGain and R128 normalization; media classification (`stik`, `hdvd`); codec configuration; orientation; media timestamps and edit lists; color/HDR; language and track selection; DRM/store identity; structured `iTunMOVI`/stem manifests; and unknown metadata.

Embedded artwork (`covr`) remains intact. Although it is stored outside QuickTime `trak` atoms, readers can expose it as an attached picture video stream. Removing it would remove a reader-visible stream. STRiPPR reports that it was retained.

MPEG and Matroska/WebM remain read only. Their embedded metadata is not inventoried or claimed removed.

## Primary references

- [TagLib MP4 item factory](https://github.com/taglib/taglib/blob/master/taglib/mp4/mp4itemfactory.cpp): item types, property mappings, sort/work/catalog and MusicBrainz/freeform metadata names.
- [MP4v2 metadata API](https://mp4v2.org/api/struct_m_p4_tags__s.html): catalog, TV, podcast, lyrics, artwork, encoder, and gapless metadata categories.
- [VideoLAN MP4 metadata reader](https://github.com/videolan/vlc/blob/master/modules/demux/mp4/meta.c): legacy QuickTime descriptive/credit fields, software, and playback-sensitive iTunes fields.
- [FFmpeg MOV/MP4 writer](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/movenc.c): metadata-only television, track/disc, compilation, and gapless fields.
- [ExifTool QuickTime implementation](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/QuickTime.pm): descriptive credit/freeform/location mappings and encoder/normalization distinctions.

Tests cover numeric rendering, removal in legitimate metadata containers, identical preserved bytes, decoy field names inside media/nonmetadata structures, unknown/ambiguous freeform preservation, and encoder/playback/artwork retention. Independent real-media verification compares streams, packet payloads, decoded output, and playback properties.

## Filesystem metadata and NAS output

The video allowlist is separate from filesystem attributes. Required filesystem
metadata is inventoried and verified independently of the media payload.
Quarantine, MACL when present, ACLs (including ACL flags), permissions, ownership,
file flags, modification time, and unrelated extended attributes must be
preserved. Opaque attribute values are copied unchanged through public APIs;
quarantine flags are never interpreted or weakened. Denials remain fatal except
for an explicitly refused `com.apple.provenance` copy, which produces a visible
security-tracking warning. This exception is not a claim of equivalent security
history or of complete filesystem metadata preservation. OS-created provenance
is not removed.

Some NAS mounts do not support hard links, exclusive file rename, or atomic
swap. When the required file operation reports unsupported and ordinary directory
rename is available, STRiPPR retains the original and publishes a verified
cleaned copy inside a new output folder. Permission and I/O errors do not trigger
this fallback. File,
symlink, and nonempty-directory collisions cannot be overwritten by that
operation. Unique names and prechecks avoid existing empty directories; this is
not a compare-and-swap guarantee against uncooperative namespace writers.
There is no in-place or delete-original-then-rename fallback.

Apple's [SMB rename implementation](https://github.com/apple-oss-distributions/smb/blob/main/kernel/smbfs/smbfs_vnops.c)
documents that servers without file IDs can change the reported directory inode
after rename. STRiPPR keeps an open directory anchor and checks the published
path, child identity, complete payload, and required attributes independently.
