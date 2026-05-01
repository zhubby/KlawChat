# KlawChat

一个为 Claude Code 设计的 macOS 原生聊天客户端，支持通过 Gateway 协议与 AI Agent 进行实时通信。

## 功能特性

- **多 Agent 会话管理**：同时连接和管理多个 AI Agent 会话
- **实时 WebSocket 通信**：基于 Gateway 协议的实时双向通信
- **Markdown 渲染**：完整支持 Markdown 格式的消息显示
- **可配置的连接设置**：灵活配置 Gateway URL 和认证信息
- **会话级 Agent 配置**：为每个会话单独配置系统提示词和模型参数
- **优雅的连接状态显示**：实时显示连接状态和加载进度

## 系统要求

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## 技术栈

- **SwiftUI**：现代化的声明式 UI 框架
- **MarkdownUI**：SwiftUI 的 Markdown 渲染库
- **URLSessionWebSocketTask**：原生 WebSocket 支持
- **@Observable / ObservableObject**：响应式状态管理

## 项目结构

```
KlawChat/
├── KlawChatApp.swift          # 应用入口
├── ContentView.swift          # 主界面
├── ChatModels.swift           # 数据模型定义
├── ChatViewModel.swift        # 聊天业务逻辑
├── ChatRepository.swift       # 数据仓库层
├── GatewayWebSocketClient.swift   # WebSocket 客户端
├── GatewayFrames.swift        # Gateway 协议帧定义
├── GatewaySettings.swift      # 设置存储管理
└── JSONValue.swift            # JSON 解析辅助

KlawChatTests/
└── ChatViewModelTests.swift   # 单元测试
```

## 使用方法

1. 克隆项目到本地
2. 在 Xcode 中打开 `KlawChat.xcodeproj`
3. 构建并运行 (Cmd+R)
4. 点击连接按钮配置 Gateway 地址和 Token
5. 开始与 AI Agent 对话

## Gateway 协议

KlawChat 使用 Claude Code 的 Gateway WebSocket 协议进行通信，支持：

- **工作空间同步**：自动获取可用的 Agent 列表
- **会话管理**：创建、加入和管理聊天会话
- **实时消息**：发送和接收实时消息
- **采样请求**：支持采样类型的交互请求

## 许可证

MIT License
