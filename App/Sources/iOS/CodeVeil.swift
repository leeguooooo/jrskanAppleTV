import SwiftUI

/// Colours of the terminal disguise (comments window, code veil, the
/// iPhone disguise screen).
enum TerminalStyle {
    static let background = Color(hex: 0x111111)
    static let text = Color(hex: 0xD6D6D6)
    static let dim = Color(hex: 0x8A8A8A)
    static let faint = Color(hex: 0x555555)
    static let bullet = Color(hex: 0x7FA37F)
    /// The comments window's text size, set with A−/A＋ or ⌘- / ⌘=.
    static let sizeKey = "commentsFontSize"
    static let defaultSize = 12.0
    static func adjustSize(by step: Double) {
        let current = UserDefaults.standard.object(forKey: sizeKey) as? Double ?? defaultSize
        UserDefaults.standard.set(min(22, max(10, current + step)), forKey: sizeKey)
    }
}


/// A coding agent's diff scrolling over the video (Mac) or filling the
/// disguise screen (iPhone). The picture
/// shows faintly through a terminal-coloured veil, so the viewer can still
/// follow the match while a passer-by sees code being written. Purely
/// decorative text; nothing is read from or written to disk.
struct CodeVeil: View {
    /// How opaque the veil is, 0.1 (the match shows clearly) to 0.9.
    let strength: Double
    @State private var lines: [VeilLine] = []
    @State private var cursor = 0
    @State private var serial = 0
    private let tick = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 1) {
                Spacer(minLength: 0)
                ForEach(lines) { line in row(line) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
            .clipped()
        }
        .font(.system(size: 12, design: .monospaced))
        // Keeps the code readable over a bright picture when the veil is faint.
        .shadow(color: .black.opacity(0.7), radius: 1.5)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TerminalStyle.background.opacity(strength))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if lines.isEmpty { for _ in 0..<40 { advance() } } }
        .onReceive(tick) { _ in
            // Bursts and pauses, like output arriving in chunks.
            let count = [0, 1, 1, 1, 2, 3][Int.random(in: 0..<6)]
            for _ in 0..<count { advance() }
        }
    }

    private func advance() {
        let template = CodeVeilCorpus.lines[cursor % CodeVeilCorpus.lines.count]
        cursor += 1
        serial += 1
        lines.append(VeilLine(id: serial, kind: template.kind, text: template.text,
                              number: template.kind == .header || template.kind == .summary ? nil : 100 + cursor % 400))
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
    }

    @ViewBuilder
    private func row(_ line: VeilLine) -> some View {
        switch line.kind {
        case .header:
            HStack(spacing: 6) {
                Text("⏺︎").foregroundStyle(TerminalStyle.bullet)
                Text(line.text).bold().foregroundStyle(TerminalStyle.text)
            }
            .padding(.top, 6)
        case .summary:
            Text("  ⎿  " + line.text).foregroundStyle(TerminalStyle.dim)
        case .added, .removed, .context:
            HStack(spacing: 0) {
                Text(line.number.map { String(format: "%5d ", $0) } ?? "      ")
                    .foregroundStyle(TerminalStyle.faint)
                Text(line.kind == .added ? "+ " : line.kind == .removed ? "- " : "  ")
                    .foregroundStyle(TerminalStyle.dim)
                Text(line.text)
                    .foregroundStyle(TerminalStyle.text.opacity(line.kind == .context ? 0.7 : 0.95))
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            // The bands fade with the veil; the text stays legible, so even a
            // faint veil still reads as code.
            .background(line.kind == .added ? Color(hex: 0x1F4A2A).opacity(min(0.8, strength * 0.9))
                         : line.kind == .removed ? Color(hex: 0x5A2226).opacity(min(0.8, strength * 0.9)) : Color.clear)
        }
    }
}

struct VeilLine: Identifiable {
    enum Kind { case header, summary, added, removed, context }
    let id: Int
    let kind: Kind
    let text: String
    var number: Int?
}

enum CodeVeilCorpus {
    struct Template { let kind: VeilLine.Kind; let text: String }

    private static func block(_ file: String, _ summary: String, _ body: String) -> [Template] {
        [Template(kind: .header, text: "Update(\(file))"), Template(kind: .summary, text: summary)]
            + body.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
                let line = String(raw)
                if line.hasPrefix("+") { return Template(kind: .added, text: String(line.dropFirst())) }
                if line.hasPrefix("-") { return Template(kind: .removed, text: String(line.dropFirst())) }
                return Template(kind: .context, text: String(line.dropFirst()))
            }
    }

    static let lines: [Template] = block("src/sync/session-store.ts", "Updated src/sync/session-store.ts with 9 additions and 3 removals", """
     export async function refreshSession(id: string, opts: RefreshOptions) {
    -  const row = await db.prepare("SELECT * FROM sessions WHERE id = ?").bind(id).first();
    +  const row = await db
    +    .prepare("SELECT id, user_id, expires_at, scope FROM sessions WHERE id = ?")
    +    .bind(id)
    +    .first<SessionRow>();
       if (!row) {
    -    throw new Error("session not found");
    +    return { ok: false, error: "session_not_found" } as const;
       }
    +  if (row.expires_at < Date.now()) {
    +    await revokeSession(id, "expired");
    +    return { ok: false, error: "session_expired" } as const;
    +  }
       return { ok: true, session: toSession(row) } as const;
     }
    """) + block("src/api/chat/handler.ts", "Updated src/api/chat/handler.ts with 7 additions and 2 removals", """
     router.post("/api/chat", async (c) => {
       const body = await c.req.json<ChatRequest>();
    -  const tenant = c.get("tenant");
    +  const tenant = requireTenant(c);
    +  if (!isAllowedCallback(tenant, body.callback_url)) {
    +    log.warn("callback_rejected", { host: hostOf(body.callback_url) });
    +    return c.json({ error: "callback_rejected" }, 403);
    +  }
       const job = await queue.enqueue({ tenant: tenant.id, ...body });
    -  return c.json({ id: job.id });
    +  return c.json({ id: job.id, status: "accepted" }, 202);
     });
    """) + block("src/workers/retry.ts", "Updated src/workers/retry.ts with 11 additions and 4 removals", """
     export async function withRetry<T>(fn: () => Promise<T>, attempts = 3): Promise<T> {
    -  let last: unknown;
    -  for (let i = 0; i < attempts; i++) {
    +  let last: unknown = undefined;
    +  for (let attempt = 0; attempt < attempts; attempt++) {
         try {
           return await fn();
         } catch (error) {
           last = error;
    -      await sleep(500);
    +      if (!isRetryable(error)) break;
    +      const delay = Math.min(8_000, 250 * 2 ** attempt) + Math.random() * 100;
    +      log.debug("retrying", { attempt, delay });
    +      await sleep(delay);
         }
       }
    +  metrics.increment("retry.exhausted");
       throw last;
     }
    """) + block("test/callback-allowlist.test.ts", "Updated test/callback-allowlist.test.ts with 14 additions", """
     describe("callback allowlist", () => {
    +  it("rejects hosts outside the tenant allowlist", async () => {
    +    const res = await app.request("/api/chat", post({ callback_url: "https://evil.example/hook" }));
    +    expect(res.status).toBe(403);
    +    expect(await res.json()).toEqual({ error: "callback_rejected" });
    +  });
    +
    +  it("accepts the configured callback host", async () => {
    +    const res = await app.request("/api/chat", post({ callback_url: "https://im-room.example.com/reply" }));
    +    expect(res.status).toBe(202);
    +  });
    +
    +  it("logs the rejected host without the path", async () => {
    +    await app.request("/api/chat", post({ callback_url: "https://evil.example/a/b?c=d" }));
    +    expect(logs.last()).toMatchObject({ event: "callback_rejected", host: "evil.example" });
    +  });
     });
    """) + [
        Template(kind: .header, text: "Bash(npm test -- callback-allowlist)"),
        Template(kind: .summary, text: "PASS test/callback-allowlist.test.ts (3 tests) 412ms"),
        Template(kind: .header, text: "Bash(npm run lint)"),
        Template(kind: .summary, text: "No problems found")
    ]
}
