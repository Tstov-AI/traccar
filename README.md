# Traccar GPS Tracking Server – Configuration & Data Directory

This directory contains the runtime configuration, embedded database storage, execution logs, and maintenance scripts for a production [Traccar](https://www.traccar.org/) GPS tracking server instance.

---

## Table of Contents

1. [Directory Overview & Structure](#1-directory-overview--structure)
2. [What This Directory Covers](#2-what-this-directory-covers)
3. [Configuration File: `traccar.xml`](#3-configuration-file-traccarxml)
   - [XML Document Format](#xml-document-format)
   - [Database Connection](#database-connection)
   - [Protocol Listeners (SinoTrack & OsmAnd)](#protocol-listeners-sinotrack--osmand)
   - [Web Access & PMS Integration](#web-access--pms-integration)
4. [Traccar Position Filtering Engine (`filter.*`)](#4-traccar-position-filtering-engine-filter)
   - [Why Filtering is Critical](#why-filtering-is-critical)
   - [Filter Configuration Breakdown](#filter-configuration-breakdown)
   - [Filter Log Signatures](#filter-log-signatures)
5. [Database Maintenance & Deduplication (`dedup.sql`)](#5-database-maintenance--deduplication-dedupsql)
6. [Data & Storage (`data/`)](#6-data--storage-data)
7. [Logs & Diagnostics (`logs/`)](#7-logs--diagnostics-logs)
8. [Common Operations & Administration Commands](#8-common-operations--administration-commands)

---

## 1. Directory Overview & Structure

```
traccar/
├── traccar.xml           # Main Traccar server configuration file
├── dedup.sql             # SQL script to prune duplicate position records
├── data/                 # Embedded H2 database storage and backups
│   ├── database.mv.db      # Active H2 MVStore database file (~24 MB)
│   ├── database.mv.db.bak  # Safety backup prior to maintenance (~120 MB)
│   └── database.trace.db   # H2 database SQL tracing and diagnostic log
└── logs/                 # Traccar service logs & daily archives
    ├── tracker-server.log            # Active application log
    └── tracker-server.log.YYYYMMDD   # Historical daily rotated logs
```

---

## 2. What This Directory Covers

This directory acts as the dedicated state and configuration volume for the Traccar server. It covers:

| Component | Role & Scope |
| :--- | :--- |
| **Server Configuration** | Defines database connections, listener ports, protocol whitelists, CORS origins, and filtering logic via [`traccar.xml`](file:///home/ilyasnmili/Desktop/traccar/traccar.xml). |
| **GPS Telemetry Ingestion** | Receives real-time GPS telemetry from hardware trackers (e.g. SinoTrack over H02 protocol on port `5013`) and mobile/software clients (OsmAnd on port `5055`). |
| **Data Persistence** | Manages device records, geofences, user accounts, and position histories within an embedded [H2 Database](https://www.h2database.com/) under [`data/`](file:///home/ilyasnmili/Desktop/traccar/data). |
| **Data Hygiene & Optimization** | Provides an automated filtering pipeline in [`traccar.xml`](file:///home/ilyasnmili/Desktop/traccar/traccar.xml) to drop GPS drift, invalid coordinates, and static clutter, along with an explicit cleanup script [`dedup.sql`](file:///home/ilyasnmili/Desktop/traccar/dedup.sql). |
| **System Diagnostics** | Rotates daily activity and audit logs in [`logs/`](file:///home/ilyasnmili/Desktop/traccar/logs) documenting socket handshakes, incoming hex/ASCII packets, device timeouts, and filter actions. |

---

## 3. Configuration File: `traccar.xml`

The [`traccar.xml`](file:///home/ilyasnmili/Desktop/traccar/traccar.xml) file is the primary runtime configuration consumed by Traccar during startup.

### XML Document Format

```xml
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>
<properties>
    ...
</properties>
```
Traccar uses the standard Java Properties XML DTD (`java.sun.com/dtd/properties.dtd`). Every setting is represented as an `<entry key='...'>value</entry>` node.

---

### Database Connection

```xml
<!-- Database Configuration -->
<entry key='database.driver'>org.h2.Driver</entry>
<entry key='database.url'>jdbc:h2:./data/database;DB_CLOSE_DELAY=-1;MODE=MYSQL</entry>
<entry key='database.user'>sa</entry>
<entry key='database.password'></entry>
```

- **`database.driver` (`org.h2.Driver`)**: Tells the JVM to use the embedded H2 JDBC database driver. No external database engine (such as MySQL or PostgreSQL) is required.
- **`database.url`**:
  - `jdbc:h2:./data/database`: Points to the file path `./data/database.mv.db` relative to the server working directory.
  - `DB_CLOSE_DELAY=-1`: Keeps the in-memory database cache open as long as the JVM process is alive, preventing frequent connection teardowns.
  - `MODE=MYSQL`: Enables MySQL compatibility mode so Traccar can execute queries designed for MySQL syntax against H2.
- **`database.user` / `database.password`**: Default administrative credentials for H2 (`user: sa`, `password: <empty>`).

---

#### Hosted deployment on Railway (PostgreSQL)

A second instance runs on Railway, in the `transport-saas` project, built from the `Dockerfile` in this repository (the official `traccar/traccar` image plus this `traccar.xml`):

| | |
| :--- | :--- |
| Web interface and API | `https://traccar-production-5216f591.up.railway.app` (container port `8082`) |
| SinoTrack (H02) trackers | `tramway.proxy.rlwy.net`, port `52838` (TCP, forwarded to container port `5013`) |
| Database | the `Postgres` service of the same project |

`traccar.xml` enables `config.useEnvironmentVariables`, so any entry can be overridden by an environment variable named after its key, in upper case with dots as underscores. The Railway service keeps the file as is and sets:

| Variable | Value |
| :--- | :--- |
| `DATABASE_DRIVER` | `org.postgresql.Driver` |
| `DATABASE_URL` | `jdbc:postgresql://<host>:<port>/<database>` (a JDBC address, not the `postgresql://user:pass@…` form) |
| `DATABASE_USER` / `DATABASE_PASSWORD` | the PostgreSQL credentials, referenced from the `Postgres` service |
| `LOGGER_CONSOLE` | `true`, so the log goes to the container output where Railway shows it |

Notes:

- Traccar creates its tables on first start. This database started **empty**: no users, devices or history were carried over from the H2 file of the original server. The first account registered on the web interface becomes the administrator.
- A tracker only reports here once it is told to: each SinoTrack device has to be pointed at the host and port above (they still send to the original server until then).
- Railway forwards one TCP port per service, so the OsmAnd port (`5055`) is not reachable from outside.
- The service deploys on every push to the branch it is connected to.

---

### Protocol Listeners (SinoTrack & OsmAnd)

```xml
<!-- SinoTrack Protocol Listener -->
<entry key='h02.port'>5013</entry>
<entry key='protocols.enable'>h02,osmand</entry>
```

- **`protocols.enable` (`h02,osmand`)**: By default, Traccar opens listeners for over 200 protocols, consuming excessive memory and socket descriptors. Setting this option **whitelists only the active protocols needed**:
  - `h02`: Protocol used by popular SinoTrack GPS devices (e.g., ST-901, ST-902, ST-906, Coban/H02 clones).
  - `osmand`: Universal HTTP GET/POST protocol used by the OsmAnd mobile app, Traccar Client for Android/iOS, and custom API webhooks.
- **`h02.port` (`5013`)**: Explicitly binds the H02 protocol listener to TCP/UDP port `5013`. Trackers should be pointed to `YOUR_SERVER_IP:5013`.
- *OsmAnd port*: Runs on standard default port `5055` unless overridden.

---

### Web Access & PMS Integration

```xml
<!-- Cross-origin (CORS) header for API calls from other sites -->
<entry key='web.origin'>*</entry>
```

- **`web.origin` (`*`)**: The Cross-Origin Resource Sharing (CORS) origin header value. It lets pages on other sites call the Traccar API from the browser. It does not control iframe embedding.

#### How the hotel ERP and the staff portal show vehicle positions

Neither app talks to Traccar, and Traccar's web page is not embedded anywhere. The hotel PMS reads positions from this server and serves them to both apps, which draw their own map:

```
trackers ──► Traccar ◄── PMS (server-side, every few seconds) ──► ERP "Vehicle locations" / staff portal "Vehicle map"
```

- The PMS calls `GET /api/devices` and `GET /api/positions` with HTTP Basic authentication and caches the answer for a few seconds.
- Because the call is made by the PMS server, not by a browser, this server can stay on plain HTTP and needs no public domain; only the PMS server has to reach its web port (`8082`).
- PMS `.env`: `TRACCAR_URL=http://<this server>:8082`, `TRACCAR_USER`, `TRACCAR_PASSWORD`.
- **Use a dedicated read-only user** for the PMS (Settings → Users → tick *Readonly*), linked only to the fleet's devices. The PMS shows every device that user can see.
- **Name each device with its vehicle's plate number** (for example `Vito 12345-A-6`). The PMS matches a tracker to a PMS vehicle when the device name contains the plate number, ignoring spaces and dashes, and then shows the vehicle's model and plate; otherwise it shows the device name as is.

---

## 4. Traccar Position Filtering Engine (`filter.*`)

### Why Filtering is Critical

GPS hardware trackers report coordinates periodically (every few seconds). Without filters:
1. **GPS Noise & Drift**: When vehicles are parked, GPS satellite signal multipath causes coordinates to "wander" in a starburst pattern, falsely recording non-existent movement and inflating odometer readings.
2. **Database Bloat**: A single tracker reporting every 5 seconds creates over **17,000 rows per day**. Without filtering, database disk consumption rapidly escalates (as seen when `database.mv.db` ballooned to ~120 MB before pruning).
3. **Storage & Performance Degradation**: Loading historical routes on the map slows down drastically if thousands of redundant or invalid points must be fetched over the network.

---

### Filter Configuration Breakdown

The active filtering configuration inside [`traccar.xml`](file:///home/ilyasnmili/Desktop/traccar/traccar.xml):

```xml
<!-- ── Filter Configuration (FIXED) ────────────────────────── -->
<entry key='filter.enable'>true</entry>
<entry key='filter.invalid'>true</entry>
<entry key='filter.zero'>true</entry>
<entry key='filter.duplicate'>true</entry>
<entry key='filter.static'>true</entry>

<!-- Enforce filtering even if packet has heartbeat/battery attributes -->
<entry key='filter.skipAttributes'>false</entry>

<!-- Minimum interval in seconds between 2 saved fixes from the same device -->
<entry key='filter.minPeriod'>10</entry>

<!-- Discard points closer than 20 meters (70 meters is often too large and skips turns) -->
<entry key='filter.distance'>20</entry>
```

#### Detailed Explanation of Each Filter Parameter:

| Parameter Key | Value | Purpose & Technical Behavior |
| :--- | :---: | :--- |
| **`filter.enable`** | `true` | **Master Switch**: Activates Traccar's internal position filtering pipeline. If set to `false`, all incoming positions are written directly to the database regardless of other filter settings. |
| **`filter.invalid`** | `true` | **Invalid Fix Filter**: Discards GPS packets where the GPS receiver has no satellite fix (`valid = false`). In NMEA and H02 protocols, this corresponds to status indicator `'V'` (Void) rather than `'A'` (Active). Prevents logging wildly inaccurate coordinates generated before satellite lock is acquired. |
| **`filter.zero`** | `true` | **Zero Coordinates Filter**: Drops points where Latitude = `0.0` and Longitude = `0.0` ("Null Island"). This happens during hardware boot-up or when the GPS antenna is disconnected. |
| **`filter.duplicate`** | `true` | **Duplicate Position Filter**: Drops points that have identical timestamps (`fixtime`) and coordinates to the last recorded fix. Prevents duplicate rows caused by cellular network retransmissions. |
| **`filter.static`** | `true` | **Stationary Speed Filter**: Discards consecutive updates if the device's speed is zero or below the movement threshold while parked. Completely eliminates GPS "drift" rings when a vehicle is stopped. |
| **`filter.skipAttributes`** | `false` | **Strict Filtering Enforcement**: By default in Traccar, if an incoming position packet includes special attributes (such as battery level, ignition status, alarms, or GSM signal), Traccar will *bypass* the filters to ensure the attribute is saved. Setting this to `false` **enforces position filtering strictly**, preventing periodic heartbeats from flooding the position database with duplicate stationary points. |
| **`filter.minPeriod`** | `10` | **Time Interval Limiter (Seconds)**: Enforces a minimum interval of **10 seconds** between two saved positions for the same device. Any fix arriving within 10 seconds of the prior saved fix is discarded unless significant movement occurred. *(Note: replaces the obsolete `filter.time` key).* |
| **`filter.distance`** | `20` | **Distance Threshold (Meters)**: Discards any new position if the physical distance from the previous recorded position is **less than 20 meters**. <br>• **Why 20m?** Default values (like 50m–70m) often skip sharp turns and intersections during urban driving. A 20m threshold preserves cornering accuracy while filtering out parking jitter. |
| **`filter.skipLimit`** | `1800` | **Keep-alive position (seconds)**: if no position has been saved for **30 minutes**, the next one is kept even when the filters above would drop it. Without it, a parked vehicle never gets a new position (`filter.static` drops every zero-speed fix), so its location and "last seen" go stale. Note that it only applies once a device has at least one saved position: a brand-new device that has only ever been parked shows nothing until it moves. |

---

### Filter Log Signatures

When Traccar discards a position according to these rules, it writes an `INFO` entry to [`logs/tracker-server.log`](file:///home/ilyasnmili/Desktop/traccar/logs/tracker-server.log):

- **Duplicate / Distance Filter**:
  ```text
  INFO: Position filtered by Duplicate Distance filters from device: 9171058824
  ```
  *Occurs when a device sends a new packet within < 20 meters or with duplicate coordinates.*

- **Static Filter**:
  ```text
  INFO: Position filtered by Static filters from device: 9171058824
  ```
  *Occurs when the vehicle speed is 0 km/h and the vehicle is stationary.*

- **Invalid & Static Filter**:
  ```text
  INFO: Position filtered by Invalid Static filters from device: 9171058824
  ```
  *Occurs when the device sends a packet with validity flag `'V'` (e.g. parked underground or in a garage with no satellite signal).*

---

## 5. Database Maintenance & Deduplication (`dedup.sql`)

Hardware trackers frequently retransmit packets when cellular connectivity fluctuates, leading to duplicate records in the `tc_positions` table with matching timestamps and coordinates.

The [`dedup.sql`](file:///home/ilyasnmili/Desktop/traccar/dedup.sql) script provides a query to purge these duplicate entries while preserving the earliest record:

```sql
DELETE FROM tc_positions p1
WHERE EXISTS (
    SELECT 1 FROM tc_positions p2
    WHERE p1.deviceid = p2.deviceid
      AND p1.fixtime = p2.fixtime
      AND p1.id > p2.id
);
```

### How It Works:
1. Compares each row `p1` in `tc_positions` against another row `p2` for the exact same `deviceid` and `fixtime`.
2. Where duplicates exist (`p1.id > p2.id`), only the row with the lowest auto-incrementing `id` is retained.
3. All redundant duplicate rows are deleted.

> [!TIP]
> **Database Compaction (H2 `SHRINK`):**
> Deleting rows in H2 frees pages internally but does not immediately reduce the `.mv.db` file size on disk. To reclaim physical disk space after running deduplication, execute the H2 command `SHUTDOWN COMPACT` from the H2 web console or restart the Traccar service with a compaction cycle.

---

## 6. Data & Storage (`data/`)

The [`data/`](file:///home/ilyasnmili/Desktop/traccar/data) folder stores the persistent state of the Traccar service:

- **`database.mv.db`**: The active binary H2 database (MVStore engine). Contains:
  - `tc_devices`: Registered GPS trackers, identifiers, names, and unique IDs.
  - `tc_positions`: Historical breadcrumb trail and telemetry points (lat, lon, speed, altitude, attributes).
  - `tc_users`: Web console user accounts, hashed credentials, and permissions.
  - `tc_geofences`, `tc_notifications`, `tc_groups`: System configuration and alert definitions.
- **`database.mv.db.bak`**: Snapshot backup created before major database operations or filter tuning (~120 MB). Can be used to restore database state in case of corruption.
- **`database.trace.db`**: Diagnostic trace file generated by the H2 engine during startup, connection checks, and cleanups.

---

## 7. Logs & Diagnostics (`logs/`)

The [`logs/`](file:///home/ilyasnmili/Desktop/traccar/logs) directory tracks all networking, decoding, filtering, and system events.

### Log File Breakdown:
- **`tracker-server.log`**: Active log file updated in real time.
- **`tracker-server.log.YYYYMMDD`**: Daily rotated archives (automatically rotated at midnight).

### Decoding Raw Packet Logs:
In `tracker-server.log`, you can inspect incoming raw telemetry from devices:

```text
2026-11-02 22:26:22  INFO: [T1bee3a28: h02 < 196.84.12.208] *HQ,9171058824,V8,222615,V,3030.7517,N,940.9116,W,0.00,0,021126,FFFFF9FF,604,1,4971,205242635,13,31,127,0#
```

- **`h02 < 196.84.12.208`**: Packet received via the `h02` protocol listener from device IP `196.84.12.208`.
- **`*HQ`**: SinoTrack / H02 manufacturer header.
- **`9171058824`**: Device ID / IMEI configured on the tracker.
- **`222615`**: UTC Time (22:26:15).
- **`V`**: Fix validity flag (`V` = Invalid/Void, `A` = Valid).
- **`3030.7517,N,940.9116,W`**: Latitude (30°30.7517' N) and Longitude (09°40.9116' W) in NMEA DDMM.MMMM format.
- **`0.00,0`**: Speed (0.00 knots) and Course (0 degrees).
- **`021126`**: Date (02 November 2026).

---

## 8. Common Operations & Administration Commands

### Live Log Monitoring
To monitor real-time tracker connections, incoming packets, and filter triggers:
```bash
tail -f logs/tracker-server.log
```

Filter only for device packets and filter actions:
```bash
tail -f logs/tracker-server.log | grep -E "filtered|h02"
```

### Inspect Database Size
```bash
ls -lh data/
```

### Backup Active Database
Before making changes to `traccar.xml` or running SQL maintenance, create a quick backup:
```bash
cp data/database.mv.db data/database.mv.db.$(date +%Y%m%d_%H%M%S).bak
```

### Check Positions via API
If the Traccar web service is running:
```bash
# Example local query
curl -u admin:admin "http://localhost:8082/api/positions"
```

