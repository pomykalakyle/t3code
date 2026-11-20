import { INITIAL_TERMINAL_OUTPUT_CURSOR } from "@t3tools/client-runtime/state/terminal";
import { describe, expect, it } from "vite-plus/test";

import { createFocusChatScanner, paneCommandAction } from "./paneNavigation";

const append = (data: string) =>
  ({ type: "append", data, cursor: INITIAL_TERMINAL_OUTPUT_CURSOR }) as const;
const reset = (data: string) =>
  ({ type: "reset", data, cursor: INITIAL_TERMINAL_OUTPUT_CURSOR }) as const;

describe("paneCommandAction", () => {
  it.each([
    ["pane.left", "right-panel", true, "terminal"],
    ["pane.right", "right-panel", true, "terminal"],
    ["pane.left", "right-panel", false, "composer"],
    ["pane.right", "right-panel", false, "terminal"],
    ["pane.left", "drawer", false, "composer"],
    ["pane.left", null, false, "composer"],
    ["pane.right", null, false, "nvim"],
  ] as const)("%s from %s (nvim %s) goes to %s", (command, owner, nvimFocused, expected) => {
    expect(paneCommandAction(command, { terminalFocusOwner: owner, nvimFocused })).toBe(expected);
  });
});

describe("createFocusChatScanner", () => {
  it("finds the request in new output, ended by BEL or ST", () => {
    const scan = createFocusChatScanner();
    expect(scan(append("text\x1b]7733;focus-chat\x07more"))).toBe(true);
    expect(scan(append("\x1b]7733;focus-chat\x1b\\"))).toBe(true);
    expect(scan(append("plain output"))).toBe(false);
    expect(scan(append("\x1b]7733;other\x07"))).toBe(false);
  });

  it("finds a request split across chunks", () => {
    const scan = createFocusChatScanner();
    expect(scan(append("abc\x1b]77"))).toBe(false);
    expect(scan(append("33;focus-ch"))).toBe(false);
    expect(scan(append("at\x1b"))).toBe(false);
    expect(scan(append("\\"))).toBe(true);
    expect(scan(append("\x07"))).toBe(false);
  });

  it("ignores history replayed by a reset and drops a partial request", () => {
    const scan = createFocusChatScanner();
    expect(scan(reset("\x1b]7733;focus-chat\x07"))).toBe(false);
    expect(scan(append("\x1b]7733;focus"))).toBe(false);
    expect(scan(reset("history"))).toBe(false);
    expect(scan(append("-chat\x07"))).toBe(false);
  });
});
