# Apple Foundation Models Framework Documentation Reference

> Source: [Apple Developer Documentation - Foundation Models](https://developer.apple.com/documentation/foundationmodels)

## 1. Overview and Core Concepts

The Foundation Models framework (`import FoundationModels`) provides Swift interfaces for executing inference on large language models. The framework supports three execution targets:
1. **On-Device Apple Foundation Models:** Executed locally via Apple Silicon Neural Engine, GPU, and unified memory. Inference occurs with zero network latency and without transmission of prompt data off-device, bounded by local hardware memory and thermal constraints.
2. **Private Cloud Compute (PCC):** Executed on dedicated Apple Silicon cloud servers for larger model parameters. Provides expanded context windows at the cost of network round-trip latency and network availability dependencies.
3. **Third-Party Providers:** Executed via provider-supplied Swift packages conforming to the `LanguageModel` protocol (such as Claude, Gemini, or local Core AI/MLX runtimes).

### Core Concepts

* **Protocol-Oriented Abstraction:** Decouples session orchestration from model implementation. Switching between on-device models, Private Cloud Compute, and external providers requires changing only the model initializer passed to `LanguageModelSession`.
* **Session Statefulness:** `LanguageModelSession` manages conversational turn history via an append-only `Transcript`. Multi-turn interactions retain context across invocations; single-turn operations utilize independent session instances.
* **Guided Generation:** Enforces structured, schema-compliant output at decode time via the `@Generable` and `@Guide` Swift macros. Constrained sampling restricts token selection to schema-valid tokens, eliminating parsing failures at the cost of additional per-token computation overhead during sampling.
* **Tool Calling (Function Calling):** Connects language model reasoning to native Swift execution. The model emits structured arguments matching a tool's `@Generable` schema; the framework invokes the tool's `call(arguments:)` method and appends the returned `PromptRepresentable` value to the transcript.
* **Integrated Guardrails:** System-level safety filters inspect inputs and outputs concurrently with token generation. Violations terminate generation immediately and throw `LanguageModelError.guardrailViolation`.

---

## 2. Framework Architecture and Key Classes/Protocols

```
+------------------------------------------------------------------------+
|                         LanguageModelSession                           |
|  - transcript: Transcript                                              |
|  - tools: [any Tool]                                                   |
|  - isResponding: Bool                                                  |
+-----------------------------------+------------------------------------+
                                    |
            +-----------------------+-----------------------+
            |                                               |
            v                                               v
+-----------------------+                       +-----------------------+
|  any LanguageModel    |                       |       any Tool        |
|  (SystemLanguageModel |                       |  - Arguments          |
|   or custom provider) |                       |  - Output             |
+-----------+-----------+                       |  - call(arguments:)   |
            |                                   +-----------------------+
            v
+-------------------------------+
|     LanguageModelExecutor     |
|  - warmup()                   |
|  - execute(request:channel:)  |
+-------------------------------+
```

### Protocols

#### `LanguageModel`
Defines the metadata, capabilities, and execution backend for a model instance.

```swift
public protocol LanguageModel: Sendable {
    /// Capabilities supported by the model implementation.
    var capabilities: LanguageModelCapabilities { get }
    
    /// Instantiates an executor responsible for processing generation requests.
    func makeExecutor() -> any LanguageModelExecutor
}
```

#### `LanguageModelExecutor`
The execution engine responsible for model warm-up, runtime state, and token generation streaming.

```swift
public protocol LanguageModelExecutor: Sendable {
    /// Warms up runtime memory and loads model weights or connects to remote endpoints.
    func warmup() async throws
    
    /// Executes a generation request and streams snapshots over the provided channel.
    func execute(
        request: LanguageModelExecutorGenerationRequest,
        channel: LanguageModelExecutorGenerationChannel
    ) async throws
}
```

#### `Tool`
Defines an executable capability callable by the model during session generation.

```swift
public protocol Tool: Sendable {
    /// The input argument type, parsed via guided generation.
    associatedtype Arguments: ConvertibleFromGeneratedContent
    
    /// The return type fed back into the transcript.
    associatedtype Output: PromptRepresentable

    /// Identifier exposed to the model.
    var name: String { get }
    
    /// Description guiding the model on when and how to call the tool.
    var description: String { get }

    /// Executes the tool logic.
    func call(arguments: Self.Arguments) async throws -> Self.Output
}
```

#### `PromptRepresentable`
Implemented by types convertible into prompt segments consumed by the model or produced by tools. Conforming types include `String`, `GeneratedContent`, and `Prompt`.

```swift
public protocol PromptRepresentable: Sendable {
    func makePromptSegments() -> [Transcript.Segment]
}
```

#### `ConvertibleFromGeneratedContent`
Implemented by types decodable from model-generated token streams. Synthesized automatically on types decorated with the `@Generable` macro.

---

### Key Classes and Structs

#### `SystemLanguageModel`
Concrete interface to Apple's on-device foundation model.

```swift
public final class SystemLanguageModel: LanguageModel, Sendable {
    /// The default system model instance.
    public static var `default`: SystemLanguageModel { get }

    /// Availability status of the model on the current device.
    public var availability: SystemLanguageModel.Availability { get }
    
    /// Convenience property indicating whether the model is ready for inference.
    public var isAvailable: Bool { get }
    
    /// Supported language locales for the current model assets.
    public var supportedLanguages: [Locale.Language] { get }

    /// Initializes a system language model with explicit guardrails and use case.
    public init(
        guardrails: SystemLanguageModel.Guardrails = .default,
        useCase: SystemLanguageModel.UseCase = .general
    )

    /// Verifies if a specific locale is supported.
    public func supportsLocale(_ locale: Locale) -> Bool
}
```

Nested types under `SystemLanguageModel`:
* `SystemLanguageModel.Availability`:
  ```swift
  public enum Availability: Sendable, Equatable {
      case available
      case unavailable(UnavailableReason)
      
      public enum UnavailableReason: Sendable, Equatable {
          case deviceNotEligible
          case appleIntelligenceNotEnabled
          case modelNotReady
      }
  }
  ```
* `SystemLanguageModel.Guardrails`:
  ```swift
  public struct Guardrails: Sendable, Equatable {
      public static let `default`: Guardrails
      public static let permissiveContentTransformations: Guardrails
  }
  ```
* `SystemLanguageModel.UseCase`:
  ```swift
  public struct UseCase: Sendable, Equatable {
      public static let general: UseCase
      public static let contentTagging: UseCase
  }
  ```

#### `LanguageModelSession`
Manages multi-turn state, history preservation, tool invocation, and token consumption.

```swift
public final class LanguageModelSession: @unchecked Sendable {
    /// The immutable record of all conversation events.
    public var transcript: Transcript { get }
    
    /// Indicates whether a generation task is active. Concurrent calls throw an error.
    public var isResponding: Bool { get }
    
    /// The backing language model instance.
    public var model: any LanguageModel { get }
    
    /// Registered tools available to the model.
    public var tools: [any Tool] { get }

    /// Initializes a new session with explicit model, tools, and system instructions.
    public init(
        model: any LanguageModel = SystemLanguageModel.default,
        tools: [any Tool] = [],
        instructions: Instructions? = nil
    )

    /// Initializes a session restored from an existing transcript.
    public init(
        model: any LanguageModel = SystemLanguageModel.default,
        tools: [any Tool] = [],
        transcript: Transcript
    )

    /// Convenience initializer with raw string instructions.
    public convenience init(instructions: String)

    /// Executes a prompt and yields the full response after generation terminates.
    public func respond(
        to prompt: any PromptRepresentable,
        options: GenerationOptions = .init()
    ) async throws -> LanguageModelSession.Response

    /// Executes a prompt and decodes output into a type conforming to @Generable.
    public func respond<T: ConvertibleFromGeneratedContent>(
        to prompt: any PromptRepresentable,
        generating type: T.Type,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = .init()
    ) async throws -> T

    /// Returns an asynchronous stream yielding incremental snapshots of string content.
    public func streamResponse(
        to prompt: any PromptRepresentable,
        options: GenerationOptions = .init()
    ) -> LanguageModelSession.ResponseStream<String>

    /// Returns an asynchronous stream yielding partially constructed instances of T.
    public func streamResponse<T: ConvertibleFromGeneratedContent>(
        to prompt: any PromptRepresentable,
        generating type: T.Type,
        includeSchemaInPrompt: Bool = true,
        options: GenerationOptions = .init()
    ) -> LanguageModelSession.ResponseStream<T>
}
```

#### `LanguageModelSession.Response`
```swift
extension LanguageModelSession {
    public struct Response: Sendable {
        /// Generated text content.
        public let content: String
        
        /// Token consumption statistics.
        public let usage: Usage
        
        /// New transcript entries created during generation.
        public let transcriptEntries: [Transcript.Entry]
        
        public struct Usage: Sendable {
            public let promptTokens: Int
            public let generatedTokens: Int
            public let totalTokens: Int
        }
    }
}
```

#### `LanguageModelSession.ResponseStream<T>`
```swift
extension LanguageModelSession {
    public struct ResponseStream<Element>: AsyncSequence, Sendable {
        public typealias AsyncIterator = Iterator
        
        public func makeAsyncIterator() -> Iterator
        
        /// Blocks until generation completes and returns the consolidated Response.
        public func collect() async throws -> LanguageModelSession.Response
        
        public struct Iterator: AsyncIteratorProtocol {
            public mutating func next() async throws -> Element?
        }
    }
}
```

#### `GenerationOptions`
Controls sampling algorithms and resource limits per generation invocation.

```swift
public struct GenerationOptions: Sendable {
    /// Randomness metric between 0.0 and 2.0. Lower values yield deterministic tokens.
    public var temperature: Double?
    
    /// Token selection strategy.
    public var samplingMode: SamplingMode?
    
    /// Upper limit on output tokens generated.
    public var maximumResponseTokens: Int?
    
    /// Policy governing tool execution during this call.
    public var toolCallingMode: ToolCallingMode?

    public init(
        temperature: Double? = nil,
        samplingMode: SamplingMode? = nil,
        maximumResponseTokens: Int? = nil,
        toolCallingMode: ToolCallingMode? = nil
    )

    public enum SamplingMode: Sendable {
        case greedy
        case random(temperature: Double)
    }

    public enum ToolCallingMode: Sendable {
        case allowed
        case required
        case disallowed
    }
}
```

#### `Transcript`, `Entry`, and `Segment`
Represents the structural ledger of an interaction.

```swift
public struct Transcript: Sendable, Equatable {
    public var entries: [Entry]

    public enum Entry: Sendable, Equatable {
        case instructions(Instructions)
        case prompt(Prompt)
        case response(String)
        case reasoning(String)
        case toolCall(name: String, arguments: String)
        case toolOutput(name: String, content: String)
    }

    public enum Segment: Sendable, Equatable {
        case text(String)
        case structure(String)
        case attachment(Attachment)
    }

    public struct Attachment: Sendable, Equatable {
        public let identifier: String
        public let mimeType: String
        public let data: Data
    }
}
```

#### Macros: `@Generable` and `@Guide`
* `@Generable(description: String? = nil)`: Attached to `struct` or `enum` declarations. Synthesizes `ConvertibleFromGeneratedContent` conformance and builds runtime generation schemas.
* `@Guide(description: String, _ constraints: GuideConstraint...)`: Attached to stored properties inside `@Generable` types. Supplies metadata and runtime value restrictions (e.g. `.range(1...10)`, `.count(3)`).

---

## 3. Swift Code Examples

### 3.1 Availability Verification and Model Initialization

```swift
import FoundationModels

func initializeSystemSession() -> LanguageModelSession? {
    let model = SystemLanguageModel(
        guardrails: .default,
        useCase: .general
    )

    switch model.availability {
    case .available:
        return LanguageModelSession(
            model: model,
            instructions: Instructions {
                "You are an internal operations assistant. Answer concisely."
            }
        )
    case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible:
            print("Device hardware lacks Apple Intelligence neural engine specifications.")
        case .appleIntelligenceNotEnabled:
            print("Apple Intelligence is disabled in System Settings.")
        case .modelNotReady:
            print("Model weights are downloading or compiling.")
        @unknown default:
            print("Unknown model unavailability status.")
        }
        return nil
    }
}
```

### 3.2 Synchronous Prompt Execution and Token Usage

```swift
import FoundationModels

func executePrompt(session: LanguageModelSession) async throws {
    guard !session.isResponding else {
        throw LanguageModelError.rateLimited(.init())
    }

    let options = GenerationOptions(
        temperature: 0.2,
        samplingMode: .greedy,
        maximumResponseTokens: 512
    )

    let response = try await session.respond(
        to: "Summarize the quarterly operating costs from the report.",
        options: options
    )

    print("Response Content: \(response.content)")
    print("Prompt Tokens: \(response.usage.promptTokens)")
    print("Generated Tokens: \(response.usage.generatedTokens)")
    print("Total Tokens: \(response.usage.totalTokens)")
}
```

### 3.3 Streaming Response Execution

```swift
import FoundationModels

func streamPromptOutput(session: LanguageModelSession) async {
    let stream = session.streamResponse(to: "Outline the deployment stages for visionOS 26.")

    do {
        // stream yields cumulative snapshots containing generated content up to that turn
        for try await snapshot in stream {
            print("Current Snapshot: \(snapshot)")
        }

        // Collect consolidated metadata once iteration finishes
        let finalResponse = try await stream.collect()
        print("Total token count consumed: \(finalResponse.usage.totalTokens)")
    } catch let error as LanguageModelError {
        handleModelError(error)
    } catch {
        print("Unexpected streaming error: \(error.localizedDescription)")
    }
}
```

### 3.4 Guided Generation (Structured Output)

```swift
import FoundationModels

@Generable(description: "Database query configuration")
struct QuerySpecification {
    @Guide(description: "Target database table name")
    var table: String

    @Guide(description: "Maximum records returned", .range(1...100))
    var recordLimit: Int

    @Guide(description: "Indexed columns to project into results")
    var projectedColumns: [String]
}

func generateStructuredQuery(session: LanguageModelSession) async throws -> QuerySpecification {
    let spec: QuerySpecification = try await session.respond(
        to: "Extract records from users table, limiting to 25 rows, projecting id and email.",
        generating: QuerySpecification.self,
        includeSchemaInPrompt: true
    )
    return spec
}
```

### 3.5 Tool Definition and Tool Calling

```swift
import FoundationModels

struct FetchCustomerMetricTool: Tool {
    let name = "fetchCustomerMetric"
    let description = "Retrieves telemetry metrics for an identified customer account."

    @Generable
    struct Arguments {
        @Guide(description: "Customer identifier UUID string")
        var customerId: String

        @Guide(description: "Telemetry metric key")
        var metricKey: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Deterministic I/O or network query
        return "Customer \(arguments.customerId) \(arguments.metricKey) value: 98.4%"
    }
}

func executeAgentSession() async throws {
    let tool = FetchCustomerMetricTool()
    let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        tools: [tool],
        instructions: Instructions {
            "Use available tools to fetch account telemetry before answering user queries."
        }
    )

    let options = GenerationOptions(toolCallingMode: .required)
    let response = try await session.respond(
        to: "What is the uptime metric for customer acc-98124?",
        options: options
    )
    print("Agent Response: \(response.content)")
}
```

### 3.6 Guardrail Configuration and Handling

```swift
import FoundationModels

func runWithPermissiveGuardrails() async {
    // Permissive setting relaxes heuristics for text transformations while retaining core safety bounds
    let permissiveModel = SystemLanguageModel(
        guardrails: .permissiveContentTransformations,
        useCase: .general
    )
    
    let session = LanguageModelSession(model: permissiveModel)
    
    do {
        let response = try await session.respond(to: "Filter and redact raw user inputs.")
        print(response.content)
    } catch LanguageModelError.guardrailViolation(let details) {
        print("Content flagged by guardrail policy. Request terminated. Details: \(details)")
    } catch {
        print("Inference failed: \(error)")
    }
}
```

---

## 4. Availability, Platform Requirements, and Error Handling

### Platform Requirements

| Dimension | Specification |
| :--- | :--- |
| **Minimum Operating Systems** | iOS 26.0+, iPadOS 26.0+, macOS 26.0+, visionOS 26.0+ |
| **Hardware Architecture** | Apple Silicon SoC with Neural Engine support (M-series, A17 Pro or later) |
| **System Settings** | Apple Intelligence toggle enabled under System Settings > Apple Intelligence & Siri |
| **Asset State** | On-device foundation model weights downloaded and compiled |
| **On-Device Context Limit** | 4,096 tokens total window per interaction turn (prompt + output) |

### Error Taxonomy: `LanguageModelError`

All runtime failures across built-in models and conforming third-party providers map into `LanguageModelError`:

```swift
public enum LanguageModelError: Error, Sendable {
    /// Total tokens across prompt and context exceed model maximum window.
    case contextSizeExceeded(ContextSizeExceeded)
    
    /// Concurrency or rate ceiling breached.
    case rateLimited(RateLimited)
    
    /// Model refused prompt evaluation due to alignment constraints.
    case refusal(Refusal)
    
    /// Inference execution exceeded allotted timeout boundary.
    case timeout(Timeout)
    
    /// Input prompt or generated token breached safety policy guardrail.
    case guardrailViolation(GuardrailViolation)
    
    /// Invoked feature (e.g. streaming, tool calling) is unsupported by active model.
    case unsupportedCapability(UnsupportedCapability)
    
    /// Transcript payload contains incompatible attachment or segment formats.
    case unsupportedTranscriptContent(UnsupportedTranscriptContent)
}
```

### Exhaustive Error Handling Pattern

```swift
import FoundationModels

func handleModelError(_ error: Error) {
    guard let modelError = error as? LanguageModelError else {
        print("Non-framework error: \(error.localizedDescription)")
        return
    }

    switch modelError {
    case .contextSizeExceeded:
        // Operational trade-off: Truncating transcript preserves session continuation at the cost of earlier context
        print("Error: Context token window exceeded. Prune transcript entries.")

    case .rateLimited:
        // Operational trade-off: Non-streaming respond(to:) reduces rate-limiting frequency relative to open streams
        print("Error: Model execution is rate limited. Back off or transition from stream to batch respond.")

    case .refusal:
        print("Error: Model refused to process prompt under current alignment policy.")

    case .timeout:
        print("Error: Inference failed to finish within timeout window.")

    case .guardrailViolation:
        print("Error: Input or output violated Apple safety guardrails. System cannot disable this policy.")

    case .unsupportedCapability:
        print("Error: Selected LanguageModel backend lacks support for the requested capability.")

    case .unsupportedTranscriptContent:
        print("Error: Transcript contains segment data not ingestible by the active model.")

    @unknown default:
        print("Error: Unknown LanguageModelError variant encountered.")
    }
}
```
