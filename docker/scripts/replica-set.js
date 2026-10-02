// 2026-09-13: rs.initiate() branch REMOVED deliberately.
// This file is the mongodb healthcheck (compose.yml: mongosh --quiet /scripts/replica-set.js).
// The old `try { rs.status() } catch { rs.initiate(...) }` form meant that if mongod ever
// came up on an empty or damaged dbPath, the healthcheck would silently build a brand-new
// rs0 and report the container healthy on an empty database — the 2026-05-25 failure mode.
// rs0 is already initiated and its dbPath is pinned to an external volume, so auto-init is
// never wanted on this host. A failure here must surface as an unhealthy container.
// 2026-10-02 (cleanup D3): keep mongod in `quiet` mode (drops the connection accepted/ended
// lines this 5-second healthcheck itself generates, ~42% of the log). Runtime setting, so it
// is re-applied on every healthcheck and survives mongod restarts. Wrapped so it can NEVER
// affect the health result - rs.status() below remains the only assertion.
try { db.adminCommand({ setParameter: 1, quiet: true }); } catch (e) {}
rs.status()
