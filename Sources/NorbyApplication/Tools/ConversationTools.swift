import Hail

/// Assembles the tool set for one conversation turn. The agent runtime calls
/// this per turn; the returned tools are everything the model may address
/// directly. Memory is deliberately absent: nothing the model can call writes
/// saved facts — Conversation's background extraction pass is the sole writer.
public enum ConversationTools {
    public static func make(
        context: AgentTurnContext,
        attachmentResolver: AttachmentResolver,
        searchBackend: WebSearchBackend = .duckDuckGo
    ) -> [any Tool] {
        var tools: [any Tool] = [
            WebSearchTool(backend: searchBackend),
            FetchURLTool(),
            LocationTool(),
            NowTool(),
            FetchAttachmentTool(resolver: attachmentResolver),
        ]
        tools += ScheduleTools(context: context).tools
        tools += WeatherTools().tools
        tools += TimerTools(context: context).tools
        return tools
    }
}
