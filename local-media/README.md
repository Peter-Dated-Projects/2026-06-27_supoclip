# local-media

Drop large video files here to process them **in place** — the system reads
them directly and never downloads, copies, or uploads them into its storage or
database.

This folder is mounted into the backend and worker containers at `/app/input`
(read-only). Anything you put here on the host is instantly visible to the
containers.

## Usage

1. Drop your file in here, e.g.:

   ```
   local-media/2026-05-18 12-04-29.mp4
   ```

2. Start a task with the source `url` pointing at the **container** path
   (prefix `local://` + the absolute path `/app/input/<filename>`):

   ```json
   {
     "url": "local:///app/input/2026-05-18 12-04-29.mp4",
     "user_id": "<your-user-id>"
   }
   ```

   Note the three slashes: `local://` + `/app/input/...`.

## Notes

- The mount is read-only (`:ro`), so the system can never modify or delete
  your source files.
- Media files dropped here are git-ignored; only this README and `.gitignore`
  are tracked.
- If you run the worker natively on Windows (no Docker), skip the mount and
  pass the host path directly: `local://C:\path\to\video.mp4`.
