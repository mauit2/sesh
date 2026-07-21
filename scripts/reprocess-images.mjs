// reprocess-images.mjs
//
// ONE-TIME cleanup of images uploaded before the egress fixes. For every
// existing object it:
//   • shrinks the original in place (only if that saves >10%), so the same URL
//     now serves fewer bytes,
//   • writes the ~512px `_thumb` sibling the app fetches for small views,
//   • stamps a 1-year Cache-Control on everything.
//
// It is idempotent and safe to re-run: already-small originals are left byte-
// for-byte intact (just re-stamped), and existing thumbnails are skipped.
//
// The service_role key is read from the environment — it is NEVER stored in
// this file. Do not commit the key.
//
// Setup (once):   cd scripts && npm install
// Preview:        SUPABASE_SERVICE_ROLE_KEY=xxx node reprocess-images.mjs --dry-run
// Run:            SUPABASE_SERVICE_ROLE_KEY=xxx node reprocess-images.mjs
// One bucket:     SUPABASE_SERVICE_ROLE_KEY=xxx node reprocess-images.mjs --bucket=avatars

import { createClient } from '@supabase/supabase-js'
import sharp from 'sharp'

// Public project URL (not a secret — same value lives in migration 028).
const SUPABASE_URL = 'https://lltuozmbxacxiepardys.supabase.co'

const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!KEY) {
  console.error('✗ Set SUPABASE_SERVICE_ROLE_KEY in the environment first.')
  console.error('  e.g. SUPABASE_SERVICE_ROLE_KEY=xxxxx node reprocess-images.mjs --dry-run')
  process.exit(1)
}

const DRY = process.argv.includes('--dry-run')
const bucketArg = process.argv.find(a => a.startsWith('--bucket='))?.split('=')[1]

const supabase = createClient(SUPABASE_URL, KEY, { auth: { persistSession: false } })

const LONG_CACHE = '31536000'      // 1 year, matches StorageUploader.longCacheSeconds
const THUMB_MAX = 512              // matches DownsampledAsyncImage's thumb threshold

// Per-bucket policy — mirrors what the app now does on upload.
const POLICY = {
  'avatars':       { thumb: false, originalMax: 256,  quality: 82 },
  'recap-photos':  { thumb: true,  originalMax: 1400, quality: 72 },
  'session-snaps': { thumb: true,  originalMax: 1280, quality: 62 },
  'event-covers':  { thumb: true,  originalMax: 1400, quality: 72 },
  'stories':       { thumb: true,  originalMax: 1280, quality: 65 },
}

const isThumb = name => /_thumb\.[a-z0-9]+$/i.test(name)
const thumbPath = p => {
  const i = p.lastIndexOf('.')
  return i < 0 ? `${p}_thumb` : `${p.slice(0, i)}_thumb${p.slice(i)}`
}
const kb = n => `${Math.round(n / 1024)}KB`

// Supabase's list is per-prefix and returns sub-folders as entries with a null
// id. Walk the tree to collect every real file path.
async function listAll(bucket, prefix = '') {
  const out = []
  const LIMIT = 100
  let offset = 0
  for (;;) {
    const { data, error } = await supabase.storage.from(bucket).list(prefix, {
      limit: LIMIT, offset, sortBy: { column: 'name', order: 'asc' },
    })
    if (error) throw error
    if (!data?.length) break
    for (const entry of data) {
      const full = prefix ? `${prefix}/${entry.name}` : entry.name
      if (entry.id === null) out.push(...await listAll(bucket, full))   // folder
      else out.push(full)                                              // file
    }
    if (data.length < LIMIT) break
    offset += LIMIT
  }
  return out
}

async function download(bucket, path) {
  const { data, error } = await supabase.storage.from(bucket).download(path)
  if (error) throw error
  return Buffer.from(await data.arrayBuffer())
}

async function upload(bucket, path, buf) {
  if (DRY) return
  const { error } = await supabase.storage.from(bucket).upload(path, buf, {
    contentType: 'image/jpeg', cacheControl: LONG_CACHE, upsert: true,
  })
  if (error) throw error
}

async function run() {
  const buckets = bucketArg ? [bucketArg] : Object.keys(POLICY)
  let shrunk = 0, thumbs = 0, saved = 0, errors = 0

  for (const bucket of buckets) {
    const policy = POLICY[bucket]
    if (!policy) { console.log(`\n(skip unknown bucket: ${bucket})`); continue }
    console.log(`\n=== ${bucket} ===`)

    let paths
    try { paths = await listAll(bucket) }
    catch (e) { console.log(`  (skip: ${e.message})`); continue }

    const existingThumbs = new Set(paths.filter(isThumb))
    const originals = paths.filter(p => !isThumb(p))

    for (const path of originals) {
      try {
        const src = await download(bucket, path)

        // 1) Shrink the original — only overwrite with the re-encode if it
        //    actually saves >10% (avoids needless generation loss on images
        //    that are already small). Either way we re-upload to stamp the
        //    long Cache-Control.
        const reencoded = await sharp(src)
          .rotate()
          .resize({ width: policy.originalMax, height: policy.originalMax, fit: 'inside', withoutEnlargement: true })
          .jpeg({ quality: policy.quality })
          .toBuffer()

        if (reencoded.length < src.length * 0.9) {
          await upload(bucket, path, reencoded)
          saved += src.length - reencoded.length
          shrunk++
          console.log(`  shrink ${path}: ${kb(src.length)} → ${kb(reencoded.length)}`)
        } else {
          await upload(bucket, path, src)   // keep bytes, just refresh cache-control
        }

        // 2) Thumbnail sibling for the photo buckets.
        if (policy.thumb) {
          const tp = thumbPath(path)
          if (!existingThumbs.has(tp)) {
            const thumb = await sharp(src)
              .rotate()
              .resize({ width: THUMB_MAX, height: THUMB_MAX, fit: 'inside', withoutEnlargement: true })
              .jpeg({ quality: 55 })
              .toBuffer()
            await upload(bucket, tp, thumb)
            thumbs++
            console.log(`  thumb  ${tp}: ${kb(thumb.length)}`)
          }
        }
      } catch (e) {
        errors++
        console.log(`  ✗ ${path}: ${e.message}`)
      }
    }
  }

  console.log(`\n${DRY ? '[dry run] ' : ''}Done. shrunk=${shrunk} thumbnails=${thumbs} ` +
              `errors=${errors} reclaimed≈${(saved / 1024 / 1024).toFixed(1)}MB`)
}

run().catch(e => { console.error(e); process.exit(1) })
