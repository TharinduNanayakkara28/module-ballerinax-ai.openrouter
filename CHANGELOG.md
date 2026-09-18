# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- [`ModelProvider` client class implementing `ai:ModelProvider` interface for LLM chat and structured content generation via OpenRouter](https://github.com/wso2-enterprise/integration-engineering/issues/45)
- `EmbeddingProvider` client class implementing `ai:EmbeddingProvider` interface for vector embedding generation via OpenRouter.
- `ModelProvider.chatAsStream` and `ModelProvider.generateAsStream` for streaming chat completions over OpenRouter's Server-Sent Event API.

[Unreleased]: https://github.com/ballerina-platform/module-ballerinax-ai.openrouter/compare/v1.0.0...HEAD
