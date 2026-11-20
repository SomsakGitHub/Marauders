// Tests of backend/scripts/lib/deploy.mjs (the guarded deploy and the staging-only dev server) and of the CLIs'
// refusals. Every step of a deploy is a spy: nothing here runs wrangler, git, npm or touches the network.
//
// Usage: npm run test:scripts

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import {
  assertDeployable,
  assertStagingVars,
  checkHealth,
  currentVersionId,
  isDirty,
  loginProblem,
  rollbackHint,
  runDeploy,
  versionLabel,
  wranglerDeployArgs,
  wranglerDevArgs,
} from "../../scripts/lib/deploy.mjs";
import { BACKEND_DIR, UsageError, loadEnvironments, parseCli } from "../../scripts/lib/targets.mjs";

const ENVIRONMENTS = loadEnvironments();
const DB_PASSWORD = "pw-for-the-deploy-test";
const DATABASE_URL = `postgres://alice:${DB_PASSWORD}@ep-x-pooler.eu-west-2.aws.neon.tech/neondb?sslmode=require`;

// What `wrangler whoami --json` leaves for a working login: the shape of a real answer (stdout, exit status 0), the values made
// up. The real answers of a login that does not work were read from wrangler 4.150.0: no login at all prints {"loggedIn":false}
// and exits 1; a login that expired and could not be refreshed prints nothing on stdout and exits 1. Without --json both of
// them can end in "You are not authenticated" or an error with exit status 0 or 1, which is why the deploy asks for the JSON.
const ACCOUNT_EMAIL = "someone@example.test";
const LOGGED_IN = {
  status: 0,
  output: JSON.stringify(
    { loggedIn: true, authType: "OAuth Token", email: ACCOUNT_EMAIL, accounts: [{ id: "0".repeat(32), name: "Test account", type: "standard" }] },
    null,
    2,
  ),
};
const NOT_LOGGED_IN = { status: 1, output: '{"loggedIn":false}\n' };
const EXPIRED_LOGIN = { status: 1, output: "" };

/** A deploy whose every step is a spy. `calls` lists what ran, in order. */
function harness({ name = "production", dirty = false, sha = "1d02680", failAt, answers, previous = "prev-version-id", login = LOGGED_IN } = {}) {
  const calls = [];
  const logs = [];
  const deployArgs = [];
  const fetched = [];
  const label = dirty ? `${sha}-dirty` : sha;
  const queue = answers ?? [{ environment: name, version: label }];
  let next = 0;
  const input = {
    name,
    config: ENVIRONMENTS[name],
    databaseUrl: DATABASE_URL,
    git: { shortSha: async () => sha, dirtyBackend: async () => dirty },
    steps: {
      whoami: async () => {
        calls.push("login");
        return login;
      },
      runTests: async () => {
        calls.push("tests");
        if (failAt === "tests") throw new Error("tests failed");
      },
      showMigrationPlan: async () => {
        calls.push("plan");
        if (failAt === "plan") throw new UsageError("an applied migration file was edited");
      },
      previousVersionId: async () => {
        calls.push("previous");
        return previous;
      },
      migrate: async () => {
        calls.push("migrate");
        if (failAt === "migrate") throw new Error("migration failed");
      },
      wranglerDeploy: async (args) => {
        calls.push("deploy");
        deployArgs.push(args);
      },
    },
    confirm: async (phrase) => {
      calls.push(`confirm(${phrase})`);
      if (failAt === "confirm") throw new UsageError("not confirmed");
    },
    fetchFn: async (url) => {
      calls.push("health");
      fetched.push(url);
      const answer = queue[Math.min(next++, queue.length - 1)];
      return new Response(JSON.stringify({ status: "ok", ...answer }), { status: 200 });
    },
    log: (line) => logs.push(line),
    health: { attempts: 3, delayMs: 0, sleep: async () => {} },
  };
  return { input, calls, logs, deployArgs, fetched };
}

test("versionLabel marks a dirty tree", () => {
  assert.equal(versionLabel("1d02680", false), "1d02680");
  assert.equal(versionLabel("1d02680", true), "1d02680-dirty");
});

test("isDirty counts an untracked new file", () => {
  assert.equal(isDirty("?? backend/scripts/new.mjs\n"), true);
  assert.equal(isDirty(" M backend/src/index.ts\n"), true);
  assert.equal(isDirty(""), false);
  assert.equal(isDirty("\n"), false);
});

test("wranglerDeployArgs always names the environment, and production's name is an empty argument", () => {
  assert.deepEqual(wranglerDeployArgs(ENVIRONMENTS.staging, "abc1234"), ["deploy", "--env", "staging", "--var", "GIT_SHA:abc1234"]);
  assert.deepEqual(wranglerDeployArgs(ENVIRONMENTS.production, "abc1234"), ["deploy", "--env", "", "--var", "GIT_SHA:abc1234"]);
});

test("assertDeployable refuses a dirty production only", () => {
  assert.throws(() => assertDeployable("production", true), (error) => error instanceof UsageError && /clean|commit/i.test(error.message));
  assertDeployable("production", false);
  assertDeployable("staging", true);
  assertDeployable("staging", false);
});

test("production refuses a dirty backend before anything runs", async () => {
  const { input, calls } = harness({ dirty: true });
  await assert.rejects(runDeploy(input), UsageError);
  assert.deepEqual(calls, [], "not even the login check or the tests ran");
});

test("staging deploys a dirty tree and labels the version -dirty", async () => {
  const { input, calls, deployArgs } = harness({ name: "staging", dirty: true });
  await runDeploy(input);
  assert.deepEqual(deployArgs, [["deploy", "--env", "staging", "--var", "GIT_SHA:1d02680-dirty"]]);
  assert.ok(calls.includes("health"), "the health check expected the same label and passed");
});

test("the steps run in order", async () => {
  const production = harness();
  await runDeploy(production.input);
  assert.deepEqual(production.calls, ["login", "tests", "plan", "confirm(production)", "previous", "migrate", "deploy", "health"]);

  const staging = harness({ name: "staging" });
  await runDeploy(staging.input);
  assert.deepEqual(staging.calls, ["login", "tests", "plan", "confirm(null)", "previous", "migrate", "deploy", "health"]);
});

// The login is checked before the tests: they take minutes, and a login that is dead shows otherwise only at `wrangler deploy`,
// after the tests, after the phrase and after the migrations were applied to the database (2026-11-20, minor 21).
test("a login that does not work stops the run before anything else runs, the tests included", async () => {
  for (const login of [
    NOT_LOGGED_IN,
    EXPIRED_LOGIN,
    { status: 0, output: "You are not authenticated. Please run `wrangler login`." },
    { status: null, output: "" },
  ]) {
    for (const name of ["production", "staging"]) {
      const { input, calls } = harness({ name, login });
      await assert.rejects(
        runDeploy(input),
        (error) => error instanceof UsageError && error.message.includes("wrangler login"),
        `${name} with ${JSON.stringify(login)}`,
      );
      assert.deepEqual(calls, ["login"], `${name}: not the tests, the plan, the phrase, the migration or the deploy`);
    }
  }
});

test("the login check prints nothing of what wrangler said: not the account email, with a login that works or one that does not", async () => {
  const working = harness();
  await runDeploy(working.input);
  assert.ok(!working.logs.join("\n").includes(ACCOUNT_EMAIL), "a working login");
  assert.ok(!working.logs.join("\n").includes("OAuth Token"), "a working login");

  const broken = harness({ login: { status: 1, output: LOGGED_IN.output } });
  await assert.rejects(runDeploy(broken.input), (error) => !error.message.includes(ACCOUNT_EMAIL));
  assert.ok(!broken.logs.join("\n").includes(ACCOUNT_EMAIL), "a login that does not work");
});

test("loginProblem says whether wrangler failed, could not be run, or did not report a login", () => {
  assert.match(loginProblem(NOT_LOGGED_IN), /exited with status 1/);
  assert.match(loginProblem({ status: null, output: "" }), /could not be run or did not finish/);
  assert.match(loginProblem({ status: 0, output: '{"loggedIn":false}' }), /did not report a login/);
});

test("loginProblem accepts a working login and nothing else", () => {
  assert.equal(loginProblem(LOGGED_IN), null);
  assert.equal(loginProblem({ status: 0, output: `${LOGGED_IN.output}\n` }), null, "a trailing newline");
  assert.equal(loginProblem({ status: 0, output: `a line before the JSON\n${LOGGED_IN.output}` }), null, "a line before the JSON");
  const failing = [
    ["no login at all, as wrangler answers it", NOT_LOGGED_IN],
    ["a login that expired and could not be refreshed", EXPIRED_LOGIN],
    ["no exit status: wrangler could not be started, or was killed", { status: null, output: "" }],
    ["a failing exit status over a JSON that says logged in", { status: 1, output: LOGGED_IN.output }],
    ["exit status 0 with loggedIn false", { status: 0, output: '{"loggedIn":false}' }],
    ["exit status 0 with the words of the plain command", { status: 0, output: "You are not authenticated. Please run `wrangler login`." }],
    ["exit status 0 with no output", { status: 0, output: "" }],
    ["exit status 0 with a JSON that has no loggedIn", { status: 0, output: JSON.stringify({ email: ACCOUNT_EMAIL }) }],
    ["exit status 0 with loggedIn as a string", { status: 0, output: '{"loggedIn":"true"}' }],
    ["exit status 0 with a JSON cut short", { status: 0, output: LOGGED_IN.output.slice(0, 40) }],
  ];
  for (const [what, answer] of failing) {
    const problem = loginProblem(answer);
    assert.equal(typeof problem, "string", `${what}: a sentence, not ${problem}`);
    assert.ok(problem.includes("wrangler login"), `${what}: names the fix: ${problem}`);
    assert.ok(!problem.includes(ACCOUNT_EMAIL), `${what}: never repeats the account email: ${problem}`);
    if (answer.output.trim() !== "") {
      assert.ok(!problem.includes(answer.output.trim()), `${what}: never repeats what wrangler printed`);
    }
  }
});

test("the banner comes first, names the target and hides the database credentials", async () => {
  const { input, logs } = harness();
  await runDeploy(input);
  assert.ok(logs[0].includes("deploy on production"), logs[0]);
  assert.ok(logs[0].includes("ep-x-pooler.eu-west-2.aws.neon.tech"));
  assert.ok(!logs.join("\n").includes(DB_PASSWORD));
});

test("failing tests stop the run", async () => {
  const { input, calls } = harness({ failAt: "tests" });
  await assert.rejects(runDeploy(input), /tests failed/);
  assert.deepEqual(calls, ["login", "tests"]);
});

test("a refused confirmation stops before migrate", async () => {
  const { input, calls } = harness({ failAt: "confirm" });
  await assert.rejects(runDeploy(input), UsageError);
  assert.deepEqual(calls, ["login", "tests", "plan", "confirm(production)"]);
});

test("the migration plan is shown before the phrase is asked, and a plan that fails stops the run before it", async () => {
  const { input, calls } = harness({ failAt: "plan" });
  await assert.rejects(runDeploy(input), UsageError);
  assert.deepEqual(calls, ["login", "tests", "plan"], "no phrase was asked, nothing was migrated or deployed");
});

test("a failing migration stops before deploy", async () => {
  const { input, calls } = harness({ failAt: "migrate" });
  await assert.rejects(runDeploy(input), /migration failed/);
  assert.deepEqual(calls, ["login", "tests", "plan", "confirm(production)", "previous", "migrate"]);
});

test("the previous version is read before anything is changed", async () => {
  const { input, calls } = harness();
  await runDeploy(input);
  assert.ok(calls.indexOf("previous") < calls.indexOf("migrate"));
  assert.ok(calls.indexOf("previous") < calls.indexOf("deploy"));
});

test("a health answer for another environment or version fails the run and rolls nothing back", async () => {
  for (const wrong of [
    { environment: "staging", version: "1d02680" },
    { environment: "production", version: "oldoldo" },
  ]) {
    const { input, calls, logs } = harness({ answers: [wrong] });
    await assert.rejects(
      runDeploy(input),
      (error) => /health/i.test(error.message) && error.message.includes("production") && error.message.includes("1d02680"),
    );
    assert.equal(calls.filter((call) => call === "deploy").length, 1, "deployed once, and nothing deployed again");
    assert.ok(logs.some((line) => line.includes("wrangler rollback") && line.includes("prev-version-id")), "the hint is still printed");
  }
});

test("checkHealth retries while the old version still answers", async () => {
  const sleeps = [];
  const answers = [
    { environment: "staging", version: "old1111" },
    { environment: "staging", version: "old1111" },
    { environment: "staging", version: "new2222" },
  ];
  let next = 0;
  const result = await checkHealth({
    url: ENVIRONMENTS.staging.url,
    expectedEnvironment: "staging",
    expectedVersion: "new2222",
    fetchFn: async (url) => {
      assert.equal(url, `${ENVIRONMENTS.staging.url}/health`);
      return new Response(JSON.stringify({ status: "ok", ...answers[next++] }));
    },
    attempts: 5,
    delayMs: 7,
    sleep: async (ms) => sleeps.push(ms),
  });
  assert.deepEqual(result, { ok: true });
  assert.equal(next, 3, "stopped asking once it matched");
  assert.deepEqual(sleeps, [7, 7]);
});

test("checkHealth gives up after its attempts and names expected and actual", async () => {
  const result = await checkHealth({
    url: ENVIRONMENTS.production.url,
    expectedEnvironment: "production",
    expectedVersion: "new2222",
    fetchFn: async () => new Response(JSON.stringify({ status: "ok", environment: "production", version: "old1111" })),
    attempts: 3,
    delayMs: 0,
    sleep: async () => {},
  });
  assert.equal(result.ok, false);
  for (const needle of ["production", "new2222", "old1111"]) {
    assert.ok(result.reason.includes(needle), `${needle} in: ${result.reason}`);
  }
});

test("checkHealth treats a failing request, an error status and a non-JSON answer as not healthy yet", async () => {
  const failures = [
    async () => {
      throw new TypeError("fetch failed");
    },
    async () => new Response("down", { status: 503 }),
    async () => new Response("<html>not json</html>", { status: 200 }),
  ];
  for (const fetchFn of failures) {
    const result = await checkHealth({
      url: ENVIRONMENTS.staging.url,
      expectedEnvironment: "staging",
      expectedVersion: "x",
      fetchFn,
      attempts: 2,
      delayMs: 0,
      sleep: async () => {},
    });
    assert.equal(result.ok, false);
    assert.ok(result.reason.length > 0);
  }
});

test("rollbackHint names the previous version and the worker, or says how to find it", () => {
  const withId = rollbackHint("production", ENVIRONMENTS.production, "9448d39c-aaaa-bbbb-cccc-111122223333");
  assert.ok(withId.includes("wrangler rollback"));
  assert.ok(withId.includes("9448d39c-aaaa-bbbb-cccc-111122223333"));
  assert.ok(withId.includes(ENVIRONMENTS.production.worker));
  const without = rollbackHint("staging", ENVIRONMENTS.staging, null);
  assert.ok(without.includes("npx wrangler deployments list"));
  assert.ok(without.includes(ENVIRONMENTS.staging.worker));
});

test("currentVersionId reads the version that was serving from wrangler's JSON", () => {
  const deployments = [
    {
      id: "d-old",
      created_on: "2026-11-01T10:00:00.000000Z",
      versions: [{ version_id: "v-old", percentage: 100 }],
    },
    {
      id: "d-new",
      created_on: "2026-11-15T10:00:00.000000Z",
      versions: [
        { version_id: "v-new-small", percentage: 10 },
        { version_id: "v-new", percentage: 90 },
      ],
    },
  ];
  assert.equal(currentVersionId(JSON.stringify(deployments)), "v-new", "newest deployment, largest share, whatever the order");
  assert.equal(currentVersionId(JSON.stringify([...deployments].reverse())), "v-new");
  assert.equal(currentVersionId(JSON.stringify({ deployments })), "v-new");
  assert.equal(currentVersionId(`some banner line\n${JSON.stringify(deployments)}\n`), "v-new");
});

test("currentVersionId says null rather than guessing", () => {
  for (const text of ["", "not json", "[]", "{}", '[{"id":"x"}]', '[{"versions":[]}]', "null"]) {
    assert.equal(currentVersionId(text), null, JSON.stringify(text));
  }
});

test("dev runs staging only and refuses another environment in any spelling", () => {
  assert.deepEqual(wranglerDevArgs([]), ["dev", "--env", "staging"]);
  assert.deepEqual(wranglerDevArgs(["--port", "8788"]), ["dev", "--env", "staging", "--port", "8788"]);
  for (const extra of [["--env", "production"], ["--env=production"], ["-e", "production"], ["-eproduction"], ["--port", "1", "--env", "x"]]) {
    assert.throws(() => wranglerDevArgs(extra), UsageError, JSON.stringify(extra));
  }
});

test("dev refuses without .dev.vars.staging", (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), "deploy-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(path.join(dir, ".dev.vars"), `DATABASE_URL=${DATABASE_URL}\n`);
  assert.throws(
    () => assertStagingVars(dir),
    (error) => error instanceof UsageError && error.message.includes(".dev.vars.staging") && !error.message.includes(DB_PASSWORD),
  );
  writeFileSync(path.join(dir, ".dev.vars.staging"), "DATABASE_URL=postgres://x:y@h/db\n");
  assertStagingVars(dir);
});

test("dev refuses a staging vars file that holds production's database", (t) => {
  const dir = mkdtempSync(path.join(tmpdir(), "deploy-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  writeFileSync(path.join(dir, ".dev.vars.production"), `DATABASE_URL=${DATABASE_URL}\n`);
  writeFileSync(path.join(dir, ".dev.vars.staging"), `DATABASE_URL=${DATABASE_URL}\n`);
  assert.throws(
    () => assertStagingVars(dir),
    (error) =>
      error instanceof UsageError &&
      error.message.includes(".dev.vars.staging") &&
      error.message.includes(".dev.vars.production") &&
      !error.message.includes(DB_PASSWORD),
  );
});

test("a bare deploy never deploys", () => {
  const scripts = JSON.parse(readFileSync(path.join(BACKEND_DIR, "package.json"), "utf8")).scripts;
  assert.equal(scripts.deploy, "node scripts/deploy.mjs");
  assert.equal(scripts["deploy:staging"], "node scripts/deploy.mjs --env staging");
  assert.equal(scripts["deploy:production"], "node scripts/deploy.mjs --env production");
  assert.equal(scripts.dev, "node scripts/dev.mjs");
  assert.throws(() => parseCli([]), UsageError);
});

test("the deploy and dev CLIs refuse a missing or wrong target before they do anything", () => {
  const cases = [
    { script: "deploy.mjs", args: [], expect: "--env" },
    { script: "deploy.mjs", args: ["--env", "qa"], expect: "qa" },
    { script: "deploy.mjs", args: ["--env", "staging", "--nope"], expect: "nope" },
    { script: "deploy.mjs", args: ["--env", "staging", "extra"], expect: "extra" },
    { script: "dev.mjs", args: ["--env", "production"], expect: "staging" },
  ];
  for (const { script, args, expect } of cases) {
    const run = spawnSync(process.execPath, [path.join(BACKEND_DIR, "scripts", script), ...args], { encoding: "utf8", timeout: 20000 });
    assert.equal(run.status, 2, `${script} ${args.join(" ")} -> ${run.stderr}`);
    assert.ok(run.stderr.startsWith("error: "), run.stderr);
    assert.ok(run.stderr.includes(expect), run.stderr);
    assert.ok(!run.stderr.includes("    at "), "no stack trace");
  }
});
