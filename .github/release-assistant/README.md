# Release Assistant

Release Assistant gives repository automation a controlled way to create or update a draft GitHub release without direct release API access in the calling tool.

## Create a release

1. Update `request.json` with a new `request_id`, semantic version tag, title, and target branch or commit.
2. Replace `release-notes.md` with the release body.
3. Merge the changes into `main`.
4. The `Release Assistant` workflow creates the tag and a draft release, or updates an existing draft that uses the same tag.
5. Review the draft, upload IPA attachments, and publish it manually.

## Safety behavior

- Releases are always created as drafts.
- Empty notes and malformed semantic version tags fail validation.
- Published releases are not modified unless `allow_update_published` is deliberately set to `true`.
- The workflow has only `contents: write` permission.
