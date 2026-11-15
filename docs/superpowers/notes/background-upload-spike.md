# Background upload spike

Date: 2026-11-15
Status: Part A (the simulator) is done and recorded here. Part B (the phone) has not been run. D1 to D3 are decided after Part B.
Topic: Task 1 of `docs/superpowers/plans/2026-11-15-upload-resilience-cut-2-app.md`; the risks it measures are in "Risks to measure early" of `docs/superpowers/specs/2026-11-15-upload-resilience-design.md`.

## Part A: the simulator

### What was run

- Simulator: iPhone 17 (model identifier iPhone18,3), iOS 27.2 (build 24B8117), UDID `902C645A-22D9-47F3-86B0-3E4623B6B2A9`. Xcode 27.2 (27B52).
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

Not run yet (it needs the owner's yes).

## D1 to D3

Decided after Part B.
