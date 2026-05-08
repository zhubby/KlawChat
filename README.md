# KlawChat

A native macOS chat client for Klaw, enabling real-time communication with AI Agents via the Gateway protocol.

## Features

- Multi-agent session management
- Real-time WebSocket communication (Gateway protocol)
- Markdown message rendering
- Per-session agent configuration (system prompts, model params)
- Configurable connection settings (Gateway URL, auth tokens)
- Live connection status indicators

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## Tech Stack

- SwiftUI · MarkdownUI · URLSessionWebSocketTask · @Observable

## Getting Started

1. Clone the repo
2. Open `KlawChat.xcodeproj` in Xcode
3. Build & run (⌘R)
4. Configure Gateway URL and token
5. Start chatting

## Gateway Protocol

Communicates via Claude Code's Gateway WebSocket protocol, supporting workspace sync, session management, real-time messaging, and sampling requests.

## License

MIT
