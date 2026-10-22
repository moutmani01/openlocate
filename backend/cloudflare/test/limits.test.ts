import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { BackendError } from "@openlocate/client";
import { device, newGroupId, startBackend } from "./harness";

// The deployed configuration, with the per-IP abuse limits from wrangler.toml.
let url = "";
let dispose: () => Promise<void>;
beforeAll(async () => ({ url, dispose } = await startBackend({ limits: true })));
afterAll(() => dispose());

describe("abuse limits", () => {
  it("lets one address create only a few groups a minute", async () => {
    const results: (number | "ok")[] = [];
    for (let i = 0; i < 5; i++) {
      const d = device(url, `d${i}`);
      try {
        await d.api.createGroup(newGroupId());
        results.push("ok");
      } catch (e) {
        results.push(e instanceof BackendError ? e.status : -1);
      }
    }
    expect(results.slice(0, 3)).toEqual(["ok", "ok", "ok"]);
    expect(results.slice(3)).toEqual([429, 429]);
  });
});
