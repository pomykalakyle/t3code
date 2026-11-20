import type { TerminalOutputUpdate } from "@t3tools/client-runtime/state/terminal";

import type { TerminalFocusOwner } from "./terminalFocus";

/** Typed into a new Neovim surface's shell. */
export const NVIM_SURFACE_COMMAND = "NVIM_APPNAME=nvim-t3 nvim\r";

export type PaneCommand = "pane.left" | "pane.right";

/** What Neovim receives for each command; the nvim-t3 config maps them to window moves. */
export const NVIM_PANE_KEYS = {
  "pane.left": { key: "ArrowLeft", code: "ArrowLeft", ctrlKey: true, shiftKey: true },
  "pane.right": { key: "ArrowRight", code: "ArrowRight", ctrlKey: true, shiftKey: true },
} as const satisfies Record<PaneCommand, KeyboardEventInit>;

/**
 * What `pane.left` and `pane.right` do. Inside Neovim the key goes to it, and Neovim asks for the
 * chat itself when it has no window further left (see `createFocusChatScanner`).
 */
export function paneCommandAction(
  command: PaneCommand,
  focus: { readonly terminalFocusOwner: TerminalFocusOwner | null; readonly nvimFocused: boolean },
): "terminal" | "composer" | "nvim" {
  if (focus.terminalFocusOwner !== null) {
    return focus.nvimFocused || command === "pane.right" ? "terminal" : "composer";
  }
  return command === "pane.left" ? "composer" : "nvim";
}

const FOCUS_CHAT_SEQUENCES = ["\x1b]7733;focus-chat\x07", "\x1b]7733;focus-chat\x1b\\"];
const LONGEST_SEQUENCE = Math.max(...FOCUS_CHAT_SEQUENCES.map((sequence) => sequence.length));
const FOCUS_CHAT_PATTERN = /\x1b\]7733;focus-chat(?:\x07|\x1b\\)/g;

/**
 * Watches one terminal's output for Neovim's request to focus the chat. Only new output counts:
 * a reset replays history on attach, and acting on it would steal focus on every reconnect.
 */
export function createFocusChatScanner() {
  let carry = "";
  return (update: TerminalOutputUpdate): boolean => {
    if (update.type !== "append") {
      if (update.type === "reset") carry = "";
      return false;
    }
    const text = carry + update.data;
    let found = false;
    let end = 0;
    for (const match of text.matchAll(FOCUS_CHAT_PATTERN)) {
      found = true;
      end = match.index + match[0].length;
    }
    carry = "";
    for (let length = Math.min(text.length - end, LONGEST_SEQUENCE - 1); length > 0; length -= 1) {
      const tail = text.slice(text.length - length);
      if (FOCUS_CHAT_SEQUENCES.some((sequence) => sequence.startsWith(tail))) {
        carry = tail;
        break;
      }
    }
    return found;
  };
}
