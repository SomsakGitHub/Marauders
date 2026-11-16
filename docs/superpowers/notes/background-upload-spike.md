# Background upload spike

Date: 2026-11-15 (Part A and the first runs of Part B), 2026-11-16 (the rest of Part B)
Status: Part A (the simulator) and Part B (the phone) are done and recorded here. D1 to D3 are decided in the last section.
Topic: Task 1 of `docs/superpowers/plans/2026-11-15-upload-resilience-cut-2-app.md`; the risks it measures are in "Risks to measure early" of `docs/superpowers/specs/2026-11-15-upload-resilience-design.md`.

## Part A: the simulator

### What was run

- Simulator: iPhone 17 (model identifier iPhone18,3), iOS 27.2 (build 24B8117). Xcode 27.2 (27B52).
- A throwaway unit test, hosted in the Marauders app (process `Marauders`, bundle identifier `com.somsak.Marauders`), run through `xcodebuild test`. The test file was deleted after the runs and is not in the repository. **The app stayed in the foreground in every run.** Nothing below says what a background session does while the app is in the background, suspended, locked or relaunched; that is Part B.
- Session: `URLSessionConfiguration.background(withIdentifier:)` with a fresh identifier per run, `isDiscretionary = false`, `sessionSendsLaunchEvents = true`, cellular, expensive and constrained networks allowed, `timeoutIntervalForResource = 86400`. The configuration reported `timeoutIntervalForRequest = 60` (the default) and `waitsForConnectivity = false`. The delegate sat on its own serial `OperationQueue` and logged every call with a `ContinuousClock` offset.
- Task: `uploadTask(with:fromFile:)` on a 3,000,000-byte file, `POST http://127.0.0.1:<port>/` with `Authorization: Bearer ...`, `Idempotency-Key` and `Content-Type: application/octet-stream`, a `taskDescription` of `spike-record-<run>`, `countOfBytesClientExpectsToSend` 3,001,024 and `countOfBytesClientExpectsToReceive` 65,536.
- Receivers, all on 127.0.0.1, HTTP/1.1, `Connection: close`: cut 1's `LoopbackHTTPServer` (A1, A2), and a small `NWListener` receiver written inside the throwaway file for everything else (it can hold its answer, answer before the body, drain, or read slowly).
- Beyond the plan's A1 to A3: A4 (an answer before the body, three variants, three runs each), A1b (a slow receiver, to see more than one progress event) and two foreground controls (A1b, A4a), which show that the delegate is wired correctly and what is specific to the background session.
- Every offset below is in seconds after the moment just before `resume()`. "Never" always says how long the run waited.

### A1 and A2: which events arrive, and what the answer holds

Receiver: `LoopbackHTTPServer`, which reads the whole body and answers `201` with `{"ok":true}` (11 bytes). Events in order:

| Offset | Event | Values |
|---|---|---|
| +0.000 | `resume()` | state `running`, `taskDescription` `spike-record-A1A2` |
| +0.032 | `didSendBodyData` (the only one) | `bytesSent` 3,000,000, `totalBytesSent` 3,000,000, `totalBytesExpectedToSend` 3,000,000 |
| +0.035 | `didReceive data` | 11 bytes, `{"ok":true}`. `task.response` was already set (below) and `countOfBytesReceived` was 11 |
| +0.035 | `didFinishCollecting` (metrics) | one transaction, `http/1.1`, connection not reused, 3,000,000 request body bytes, 11 response body bytes |
| +0.035 | `didCompleteWithError` | `error` nil, `task.error` nil, state `completed` |

`task.response` at `didReceive data` and at completion was an `HTTPURLResponse` with status 201, `Content-Type: application/json`, `Content-Length: 11`, `Connection: close`, `expectedContentLength` 11, and the request URL. At completion `countOfBytesSent` was 3,000,000/3,000,000 and `countOfBytesReceived` 11/11. The server counted `receivedBodyByteCounts == [3000000]`.

The task kept its `taskDescription`. `originalRequest` kept all three headers (`Authorization: Bearer ...`, `Idempotency-Key`, `Content-Type`), so the token can be read from it. `currentRequest` had the same three plus `Accept-Language` and `User-Agent`. In the runs that used the throwaway receiver (which logs accepts) the connection was accepted 0.002 to 0.003 s after `resume()`, so nothing deferred the start.

What did not arrive:

- `urlSessionDidFinishEvents(forBackgroundURLSession:)`: never; the run waited 15 s after the completion. The same in A3 (waited 8 s), A1b (5 s) and every background A4 run (5 s).
- The response callback `urlSession(_:dataTask:didReceive:completionHandler:)`: never called in any background run. It was called in the foreground control (A1b below), so the delegate is wired correctly. In a background session the response is only visible as `task.response`.
- `taskIsWaitingForConnectivity`: never.

Afterwards `getAllTasks` listed 0 tasks, and `finishTasksAndInvalidate()` gave `didBecomeInvalidWithError(nil)` at once.

**A1b, how the progress arrives.** On loopback, 3 MB goes out in one event, which says little. The same upload to a slow receiver (32 KB every 40 ms, whole body read at +3.851) gave three `didSendBodyData` calls in the background session: +0.110 with 2,097,152 bytes, +0.528 with 524,288 more (2,621,440), +0.861 with 378,560 more (3,000,000). A foreground ephemeral session gave two: +0.113 with 2,621,440 and +1.237 with 378,560 more. So `totalBytesSent` reached 100% about three seconds before the receiver had read the body: it counts bytes handed to the socket, not bytes the server has read. `getAllTasks` at +1, +2 and +3 s listed the task with `countOfBytesSent` 3,000,000/3,000,000 and `response` nil. The completion came after the answer, +3.857 (`didReceive data` +3.856, status 200).

### A3: `getAllTasks` while the answer is held

Receiver: reads the whole body (done at +0.005), holds its answer 12 s, then answers `200` with `{"item":{}}`. `getAllTasks` was called at +1.5, +5.0, +9.0 and +11.5 s and each call returned in about 1 ms with exactly one task:

`taskIdentifier` 1, `taskDescription` `spike-record-A3`, state `running`, `countOfBytesSent` 3,000,000/3,000,000, `countOfBytesReceived` 0/0, `response` nil, and an `originalRequest` that still carried `Authorization: Bearer spike-token-A3`, `Idempotency-Key` and `Content-Type`.

The answer left the server at +12.017; `didReceive data` came at +12.021 (11 bytes, `{"item":{}}`, status 200) and `didCompleteWithError(nil)` at +12.022. `getAllTasks` right after the completion listed 0 tasks. So an in-flight task is listed with its `taskDescription` and request headers, and a finished one is gone.

### A4: an answer before the body has been read

The receiver answers `200` with `{"item":{}}` right after the request headers, while the 3 MB body is still arriving (this is what the Worker does for a key it already stored). Three runs of each variant, same bytes in every answer:

| | Control: reads the whole body, then answers | A4b: answers after the headers, keeps reading the body to its end, then closes | A4a: answers after the headers, closes at once with the body unread |
|---|---|---|---|
| `didSendBodyData` | 1 call, 3,000,000, at +0.004 to +0.005 | none; `countOfBytesSent` stayed 0/0 | none |
| `didReceive data` | `{"item":{}}` at +0.007 to +0.009 | `{"item":{}}` at +0.006 to +0.007 | never; waited 125 s |
| `task.response` | 200 | 200 | 200 (seen through `getAllTasks`, see below) |
| `didCompleteWithError` | nil at +0.008 to +0.009 | nil at +0.007 to +0.010 | never; waited 125 s |

So an early answer that the receiver drains behaves like a normal one, except that no `didSendBodyData` is delivered at all.

**A4a is different.** The delegate was told nothing for 125 s: no `didReceive data`, no `didSendBodyData`, no completion, no error. The system retried the upload by itself. The receiver saw seven connections in each of the three runs, at these offsets (each one answered `200` and closed within 2 ms):

- run 1: +0.002, +1.033, +3.050, +7.078, +15.751, +32.558, +67.563
- run 2: +0.002, +1.012, +3.166, +7.323, +15.645, +33.189, +65.652
- run 3: +0.002, +1.095, +3.114, +7.129, +15.155, +32.605, +67.102

The gaps roughly double (1, 2, 4, 8, 17, 35 s); no eighth attempt came before the run was ended at +125 s (by the doubling the next would be near +135 s). Each attempt had pushed between 524,288 and 2,621,440 bytes of the body before the connection was reset. At +120 s `getAllTasks` still listed the task in all three runs: state `running`, `taskDescription` kept, `countOfBytesSent` 0/0, `countOfBytesReceived` 0/11, and `response` an `HTTPURLResponse` with status 200 and the `{"item":{}}` answer's headers. So the 200 was visible on the task, but it never reached `didReceive data` and the task never completed within the time waited. How long the retries go on was not measured.

Ending the run with `invalidateAndCancel()` at +125 s delivered `didFinishCollecting` (seven transactions, each with a 200 response) and `didCompleteWithError` with `NSURLErrorDomain` -999 (`URLError.cancelled`, "cancelled"), while `task.response` still held the 200. A completion handler that reads `task.response` before the error would read a 200 on a cancelled task.

Foreground control for A4a (an ephemeral session, same receiver, three runs): `didReceive response` (200), `didReceive data` (`{"item":{}}`) and then `didCompleteWithError` with `NSURLErrorDomain` -1005 (`URLError.networkConnectionLost`, "The network connection was lost."), at +0.004 to +0.012 s. The error carried `_kCFStreamErrorDomainKey` 1 and `_kCFStreamErrorCodeKey` 54 (POSIX `ECONNRESET`) and an `NSUnderlyingError` of `kCFErrorDomainCFNetwork` -1005. So there a 200, its body and an error all arrive together.

These runs used HTTP/1.1 over loopback. Whether the real Worker, behind Cloudflare's HTTP/2 edge, ends like A4a, like A4b or in another way is not known from here: it needs the device check after migration 023 and the Worker deploy.

### Every error seen in Part A

| Where | Domain | Code | Cause |
|---|---|---|---|
| A4a, background, at +125 s | `NSURLErrorDomain` | -999 (`URLError.cancelled`) | the spike's own `invalidateAndCancel()` |
| A4a control, foreground | `NSURLErrorDomain` | -1005 (`URLError.networkConnectionLost`) | the receiver closed with the body unread |

`didBecomeInvalidWithError` was always nil. No other error occurred.

### What Part A shows for the later tasks

- **Task 8's loopback test of a real background session can run on the simulator.** In the hosted unit-test process a background session delivered `didSendBodyData` (one to three calls, the last reaching the total), `didReceive data` and `didCompleteWithError(nil)` with the status in `task.response`, in 35 ms for 3 MB. The test must not wait for `urlSessionDidFinishEvents` or the response callback (neither arrives with the app in the foreground), and should invalidate the session at the end.
- **A4 and the replay fallback.** If the real Worker closes the connection with the body unread (A4a), a background session reported nothing for the 125 s waited: there is no completion for the replay fallback to act on, and Try again on a stored key would show an upload that does not end (what finally ends it was not measured; the 24 h resource timeout is the ceiling the design relies on). If it drains the body (A4b) the answer arrives as a normal 200 and the clip is found. The foreground session shows a 200 and -1005 together in the A4a case, so a completion that checks the error before the status would call it a failure although the clip exists. Whether Tasks 5 to 7 need a replay-first step or a watchdog depends on what the real Worker does, which Part A cannot show.
- `getAllTasks` lists an in-flight task with its `taskDescription` and request headers, within one process. A relaunch cannot be shown on the simulator.
- D1 to D3: Part A shows nothing about them. The simulator made every first attempt within 0.002 to 0.003 s of `resume()`, which says nothing about the phone's scheduler, and no task was created from a background wake, no app left the screen and none was relaunched. The start delay, the 2-minute rule and the relaunch route are Part B's to measure.

## Part B: the phone

### What was run

- Device: iPhone 16 Pro Max, iOS 27.2.1, signed in to the production Worker. B1, B2, B4 and B8 ran on 2026-11-15, B6 and B5 on 2026-11-16; all times below are UTC.
- A throwaway Debug build of the app with a spike panel on the Upload tab, built outside the repository and never committed (its source is gone with its scratch directory). It had its own background session (`com.somsak.Marauders.spike`: `isDiscretionary = false`, `sessionSendsLaunchEvents = true`, cellular, expensive and constrained networks allowed) and used `uploadTask(with:fromFile:)` on the multipart body that the real `VideoUploadForm` and `UploadBodyStager` staged, so the phone also ran Tasks 3 and 4. Every delegate call, app-state change and launch went to a file in the app container, with a timestamp, the app state and the seconds since the process started (flushed per line); `devicectl` pulled it. A relaunched process has no console, which is why the file was the record.
- Target: the production Worker's upload endpoint, with `Authorization: Bearer ...` and an `Idempotency-Key`. The protocol was **h3** on every run (Cloudflare, Singapore edge). The deployed Worker does not read the key yet.
- Bodies: 12,398,052 bytes in B1, B2, B4 and B8 (the exported clip was 12,397,271 bytes); 6,125,152 bytes in B6 and B5 (a shorter clip).
- A slow link for the long cases: the phone's Network Link Conditioner (Settings, Developer), profile 3G. It carried 25 to 36 KB/s: the 12.4 MB body took 346 s to leave the phone (36 KB/s) and the 6.1 MB body 249 s (25 KB/s). On Wi-Fi 12 MB leaves in 0.7 s, faster than a person can leave the app, so B2 (Home right after Start) and B4 (Airplane mode during the upload) ran without the profile, were over before anything was done, and are not valid.
- Tokens: B1, B2 and B4 used the real token and made five real clips (removed from the Profile tab by the owner). B8, B6 and B5 used an invalid bearer token (40 random characters), which the Worker answers with 401 and makes nothing.
- Offsets are seconds after the moment just before `resume()` unless the text says otherwise.

### B1 and D1: how soon a task starts (foreground, Wi-Fi)

| Run | `resume()` to `requestStart` | first `didSendBodyData` | last byte out | `didCompleteWithError` | status |
|---|---|---|---|---|---|
| B1 run 1 | 0.080 | +0.182 | +0.729 | +2.018 | 201 |
| B1 run 2 | 0.084 | +0.188 | +0.698 | +1.972 | 201 |
| B1 run 3 | 0.083 | +0.189 | +0.828 | +2.187 | 201 |
| B2 (Home pressed too late) | 0.077 | +0.184 | +0.693 | +2.949 | 201 |
| B4 (profile off) | 0.080 | +0.183 | +0.701 | +2.088 | 201 |

`willBeginDelayedRequest` fired 0.001 to 0.002 s after `resume()` each time (no delay). The Worker's 201 came 1.26 to 1.37 s after the last byte (2.24 s once). Under the 3G profile the request began 0.40 s (B8), 0.40 s (B6) and 0.59 s (B5 leg 1) after `resume()`.

### B7: what reaches the delegate

The Worker's answer reached `didReceive data` every time: 709 bytes of `{"item":{...}}` for a 201 (foreground) and 35 bytes of `{"error":"authentication required"}` for a 401, in the foreground and in a process the system relaunched (B6, B5). `urlSession(_:dataTask:didReceive:completionHandler:)` was never called in any run, as in Part A; the status is in `task.response`. Every task ended with `error` nil: five 201 and six 401, and no error of any kind occurred in Part B. `countOfBytesReceived` read 70 for the 35-byte answer in the two completions delivered to a relaunched process (B6, B5 leg 1) while one 35-byte `didReceive data` arrived; it had no effect.

### B8 and R8: an answer before the body is out (invalid token, 3G profile, foreground)

The Worker answers a bad token with 401 before it reads the body. Full 12.4 MB body, profile on (task `b8a-5`):

| Offset | Event |
|---|---|
| +0.403 | `requestStart` |
| +0.513 | `didSendBodyData` 2,097,152 (the send buffer) |
| +27.9 | `didSendBodyData` 2 MiB more (4 MiB in all) |
| +57.0 to +265.6 | `didSendBodyData` 1 MiB every 28 to 35 s, with one gap of 58 s |
| +294.2 | `totalBytesSent` 12,398,052: the counter reached 100 % |
| +346.3 | `requestEnd`: the last byte left the phone, 52 s after the counter said 100 % |
| +347.5 | `responseStart` 1.25 s after the last byte; `didReceive data` 35 bytes; `didCompleteWithError(nil)`, status 401 |

Nothing came back during the 346 s the body took. The answer reached the app only after the body was out, as an ordinary completion: not as a hang and not as an error. (Whether the edge or the client held it back is not known.) So a rejected token costs the whole upload before the app learns of it, and `totalBytesSent` is no progress meter on a slow link: it reached 100 % 52 s before the data had left.

### B6 and D3: the process is ended mid-upload (3G profile, invalid token)

Start was at 10:41:17.05 (task `b6-7`); the app left the foreground 1.1 s later; at 10:42:19 the process was ended with `devicectl device process terminate --pid ... --kill` (SIGKILL) and the process list no longer showed it. The owner had been asked to lock the phone right after and not to open the app; the lock state read at 10:45:44 was "passcode required".

| When | Event |
|---|---|
| 10:45:26.755 | the last byte left the phone (249 s after the request began) |
| 10:45:28.650 | `responseEnd` |
| **10:45:28.757** | **the system relaunches the app in the background, 107 ms after `responseEnd`** (nobody opened it) |
| +0.619 s since launch | the spike recreates the session; `getAllTasks` lists `b6-7` as `completed`, 6,125,152 of 6,125,152 sent; the record files are readable |
| +0.859 | `didReceive data`, 35 bytes |
| +0.869 | `didCompleteWithError(nil)`, status 401 |
| +0.870 | `urlSessionDidFinishEvents` (no system handler had been stored) |
| +1.114 | the scene's `.backgroundTask(.urlSession(id))` closure starts, 0.24 s after the events had finished |
| +1.119 | the closure ends |

B5 leg 1 repeated it: relaunch at 10:52:48.050, 58 ms after `responseEnd`, `urlSessionDidFinishEvents` at +0.231 s, the scene closure at +0.332 s. So a SIGKILL from `devicectl` is not treated as a force quit: the system relaunches the app within about a tenth of a second of the answer. The staged body in Application Support was read by the system for the whole upload. B3 (a locked phone) was run inside this case, not on its own: besides the lock state read at 10:45:44, the relaunched process was told at 10:49:39 that protected data had become available again (`UIApplicationProtectedDataDidBecomeAvailable`, which fires when a locked phone is unlocked), so the phone was locked until then; the log does not show its lock state at the moment of the relaunch itself. The two times the brief asks for: the first `didSendBodyData` came +0.510 s after `resume()` and the completion 252.6 s after it (a measure of the 3G profile, not of the lock).

### B5 and D2: a task created from a background wake (3G profile, invalid token, Chain on)

Leg 1 (`b5-8`) started in the foreground at 10:50:30.9 and the process was ended 32 s later as in B6. The owner switched the profile off at about 10:52:40 (an inference from the leg finishing sooner; the log does not show it), so the body finished: `requestEnd` 10:52:47.867, `responseEnd` 10:52:47.992, and the system relaunched the app at 10:52:48.050. Inside that relaunch the spike created and resumed leg 2 (`b5-9`) from `didCompleteWithError` at +0.230 s (app state background); `willBeginDelayedRequest` was answered (continue loading) at +0.008 s, long before the process was suspended after +0.333 s.

| Leg | Created by | `resume()` to `requestStart` | `resume()` to `responseEnd` |
|---|---|---|---|
| 2 (`b5-9`) | the relaunched app, in the background | **223.178 s** | 234.3 s |
| 3 (`b5-10`) | the foreground app | 0.106 s | 5.3 s |
| 4 (`b5-11`) | the foreground app | 0.006 s | 4.0 s |

From +0.333 s since the relaunch until the app was started with `devicectl` at 10:56:29 the log has no line: no `didSendBodyData`, no completion, no relaunch; the process stayed alive, suspended, and the profile was off. Leg 2 began sending 0.75 s after the app became active. So a task created from a background wake does not start until the app is active again. The cause is not known; this is one run.

### B3, B2 and B4: what was not run on its own

- B3 (lock the phone during an upload) was run inside B6: the upload went on and the app was relaunched with the phone locked at least at the end, and the record files were readable.
- B2 and B4 are not valid (see "What was run"). They were not repeated: if the system reports a failure in an Airplane flap, Task 6 settles it as `failed(connection)` whatever the cause; a silent stall (Part A's A4a showed a background session retrying for minutes with no callback) would show only in the device check after Task 10, which covers Airplane mode with the real app.

### What Part B shows for the later tasks

- **Task 6's 401 row.** A 401 reaches the app only after the whole body has gone out; on a slow link that is minutes, and the body goes out a second time after the refresh. The app trades an expired token before it submits (`start` and `retry`), so a 401 means a token the Worker rejects (revoked, rotated, signed out elsewhere), which is rare. The ADR for this feature (Task 11) has to say so. There is no hang to guard against (R8).
- **Progress.** `totalBytesSent` ran 52 s ahead of the wire on the 3G profile (A1b showed the same shape on the simulator). A fraction taken from it must not be shown as done; only the completion ends an upload.
- **Task 7's reconcile after a relaunch.** `getAllTasks` listed the finished task (state `completed`, bytes sent equal to expected) at launch, 0.05 to 0.24 s before its events were delivered (B5 leg 1 and B6); in Part A a running process listed nothing straight after a completion. `pendingRecordIDs` should not filter on `.running`; if it did, the record would be marked interrupted for a moment and the completion would upgrade it, which the plan allows.
- **Task 10's relaunch.** The system relaunches the app in the background within 0.11 s of the answer, and the recreated session receives its events at once, before the scene closure runs (0.10 s and 0.24 s later). `awaitSystemEvents` must return at once when `.eventsFinished` was already applied; both relaunches needed exactly that. A task created inside the relaunch does not start (D2).

## D1 to D3

- **D1, a foreground task starts at once.** Every foreground run on Wi-Fi began its request within 0.11 s of `resume()` (B1, B2 and B4: 0.077 to 0.084 s; the two foreground legs of B5: 0.106 s and 0.006 s), and every one under the 3G profile within 0.6 s (the plan's limit is 15 s, stop above 60 s). Tasks 5 to 10 are built as written, with no deferred-start handling.
- **D2, `UploadPolicy.resubmitsWhileInBackground = false`.** The one task created from a background relaunch began 223 s after `resume()`, and only once the app was active again. The brief's rule needs 2 of 3 runs under 2 minutes for `true`, and only this one run was made, of the relaunch variant only (a task created inside the relaunch that follows an ended process; the repeat with the app only suspended was not run). One miss does not make `true` impossible on paper, but it would need two clean runs that were not made; `false` is the conservative value (it costs one missed automatic heal of a rare 401), and each repeat costs the owner about 6 minutes. The cause is not established: the design doc assumed the system treats a task created while the app is in the background as discretionary, and this run fits that without proving it. After a successful refresh, a 401 that arrives while the app is not active ends in `failed(interrupted)`, and Try again sends the same body and key with the token the refresh already replaced (a rejected refresh gives `failed(sessionEnded)`, an unavailable one `failed(unavailable)`).
- **D3, relaunch route A: the scene's `.backgroundTask(.urlSession(id))`.** After a SIGKILL the system relaunched the app in the background twice (B6, B5 leg 1), the recreated session received its events, and the scene closure ran 0.10 s and 0.24 s after them. The delegate adaptor is not needed.
- **R8, no replay-first probe in Task 7 and no watchdog for Task 6's 401 and 429 rows.** The 401 of B8 arrived as an ordinary completion 1.25 s after the last byte, not as a hang and not as an error. The stored-key answer (A4) is still unmeasured: it needs migration 023 and the Worker deploy and goes into the device check.
