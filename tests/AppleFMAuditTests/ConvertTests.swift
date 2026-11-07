import Foundation
import Testing
@testable import AppleFMAuditCore

@Suite("ConvertTests")
struct ConvertTests {
    @Test("Responses path detection")
    func testResponsesPath() {
        #expect(Convert.isResponsesPath("/v1/responses"))
        #expect(Convert.isResponsesPath("/responses"))
        #expect(Convert.isResponsesPath("/v1/responses?test=1"))
        #expect(!Convert.isResponsesPath("/v1/chat/completions"))
        #expect(!Convert.isResponsesPath("/v1/models"))
    }

    @Test("rewriteUpstream injects stream=false when omitted in chat completions")
    func testRewriteUpstreamChatCompletionsDefaultStream() {
        let inputData = Data("{\"model\":\"pcc\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}".utf8)
        let rewritten = Convert.rewriteUpstream(path: "/v1/chat/completions", body: inputData)
        #expect(rewritten.path == "/v1/chat/completions")
        #expect(rewritten.isResponses == false)
        let json = (try? JSONSerialization.jsonObject(with: rewritten.body)) as? [String: Any]
        #expect((json?["stream"] as? Bool) == false)
        #expect((json?["model"] as? String) == "pcc")
    }

    @Test("toChatRequest normalizes roles and flattens input")
    func testToChatRequest() {
        let payload: [String: Any] = [
            "model": "system",
            "instructions": "System prompt",
            "input": [
                [
                    "role": "developer",
                    "content": [
                        ["type": "input_text", "text": "Developer rule"]
                    ]
                ],
                [
                    "role": "user",
                    "content": "User question"
                ]
            ],
            "stream": true,
            "store": false
        ]

        let chat = Convert.toChatRequest(payload: payload)
        #expect((chat["model"] as? String) == "system")
        #expect((chat["stream"] as? Bool) == true)
        #expect(chat["store"] == nil)

        let messages = (chat["messages"] as? [[String: Any]]) ?? []
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "System prompt")
        #expect(messages[1]["role"] as? String == "system")
        #expect(messages[1]["content"] as? String == "Developer rule")
        #expect(messages[2]["role"] as? String == "user")
        #expect(messages[2]["content"] as? String == "User question")
    }

    @Test("chatToResponse maps chat completion to responses schema")
    func testChatToResponse() {
        let chat: [String: Any] = [
            "id": "chatcmpl-test1234",
            "model": "system",
            "created": 1700000000,
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "Hello World"
                    ]
                ]
            ],
            "usage": [
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15
            ]
        ]

        let resp = Convert.chatToResponse(chat: chat)
        #expect(resp["object"] as? String == "response")
        #expect(resp["id"] as? String == "resp_test1234")
        #expect(resp["model"] as? String == "system")

        let output = (resp["output"] as? [[String: Any]]) ?? []
        #expect(output.count == 1)
        let content = (output[0]["content"] as? [[String: Any]]) ?? []
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "Hello World")

        let usage = resp["usage"] as? [String: Any]
        #expect(usage?["input_tokens"] as? Int == 10)
        #expect(usage?["output_tokens"] as? Int == 5)
        #expect(usage?["total_tokens"] as? Int == 15)
    }

    @Test("chatSSELineToResponseFrames generates proper SSE event stream")
    func testSSEFrames() {
        var state = ResponsesSSEState()

        let line1 = "data: {\"id\":\"chatcmpl-stream1\",\"model\":\"system\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n"
        let frames1 = Convert.chatSSELineToResponseFrames(line: line1, state: &state)
        #expect(frames1.count == 3)
        #expect(frames1[0].contains("event: response.created"))
        #expect(frames1[0].contains("\"created_at\":"))
        #expect(frames1[1].contains("event: response.output_item.added"))
        #expect(frames1[2].contains("event: response.output_text.delta"))
        #expect(frames1[2].contains("Hello"))

        let line2 = "data: {\"id\":\"chatcmpl-stream1\",\"model\":\"system\",\"choices\":[{\"delta\":{\"content\":\" World\"}}]}\n"
        let frames2 = Convert.chatSSELineToResponseFrames(line: line2, state: &state)
        #expect(frames2.count == 1)
        #expect(frames2[0].contains("event: response.output_text.delta"))
        #expect(frames2[0].contains(" World"))

        let lineDone = "data: [DONE]\n"
        let framesDone = Convert.chatSSELineToResponseFrames(line: lineDone, state: &state)
        #expect(framesDone.count == 2)
        #expect(framesDone[0].contains("event: response.output_item.done"))
        #expect(framesDone[1].contains("event: response.completed"))
        #expect(framesDone[1].contains("\"created_at\":"))
        #expect(state.completed)
    }

    @Test("rewriteUpstream strips response_format when type is json_object")
    func testRewriteUpstreamStripsJsonObject() {
        let input = """
        {
          "model": "pcc",
          "messages": [{"role": "user", "content": "return json"}],
          "response_format": {"type": "json_object"}
        }
        """
        let rewritten = Convert.rewriteUpstream(path: "/v1/chat/completions", body: Data(input.utf8))
        let json = (try? JSONSerialization.jsonObject(with: rewritten.body)) as? [String: Any]
        #expect(json?["response_format"] == nil)
        #expect((json?["stream"] as? Bool) == false)
        #expect((json?["model"] as? String) == "pcc")
    }

    @Test("rewriteUpstream preserves response_format when type is json_schema")
    func testRewriteUpstreamPreservesJsonSchema() {
        let input = """
        {
          "model": "pcc",
          "messages": [{"role": "user", "content": "return structured"}],
          "response_format": {
            "type": "json_schema",
            "json_schema": {"name": "test", "schema": {"type": "object"}}
          }
        }
        """
        let rewritten = Convert.rewriteUpstream(path: "/v1/chat/completions", body: Data(input.utf8))
        let json = (try? JSONSerialization.jsonObject(with: rewritten.body)) as? [String: Any]
        let rf = json?["response_format"] as? [String: Any]
        #expect(rf != nil)
        #expect((rf?["type"] as? String) == "json_schema")
    }

    @Test("WorkBuddy client detection")
    func testWorkBuddyDetection() {
        #expect(Convert.isWorkBuddy(headers: ["User-Agent": "WorkBuddy/5.9.3 CLI/2.165.0"]))
        #expect(Convert.isWorkBuddy(headers: ["X-IDE-Type": "WorkBuddy"]))
        #expect(Convert.isWorkBuddy(headers: ["X-IDE-Name": "WorkBuddy"]))
        #expect(Convert.isWorkBuddy(headers: ["x-codebuddy-request": "1"]))
        #expect(Convert.isWorkBuddy(headers: ["X-Domain": "www.workbuddy.cn"]))
        #expect(!Convert.isWorkBuddy(headers: ["User-Agent": "curl/8.7.1"]))
    }

    @Test("Sanitize reasoning_effort removes none and non-PCC efforts")
    func testSanitizeReasoningEffort() {
        var pccNone: [String: Any] = ["model": "pcc", "reasoning_effort": "none"]
        #expect(Convert.sanitizeReasoningEffort(in: &pccNone) == true)
        #expect(pccNone["reasoning_effort"] == nil)

        var pccValid: [String: Any] = ["model": "pcc", "reasoning_effort": "medium"]
        #expect(Convert.sanitizeReasoningEffort(in: &pccValid) == false)
        #expect((pccValid["reasoning_effort"] as? String) == "medium")

        var sysWithEffort: [String: Any] = ["model": "system", "reasoning_effort": "low"]
        #expect(Convert.sanitizeReasoningEffort(in: &sysWithEffort) == true)
        #expect(sysWithEffort["reasoning_effort"] == nil)
    }

    @Test("Sanitize tools schema rewrites additionalProperties, anyOf, and pattern")
    func testSanitizeToolsSchema() {
        var payload: [String: Any] = [
            "model": "pcc",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [
                [
                    "type": "function",
                    "function": [
                        "name": "TaskCreate",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "metadata": [
                                    "type": "object",
                                    "additionalProperties": [:]
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "type": "function",
                    "function": [
                        "name": "widget_guidelines",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "modules": [
                                    "anyOf": [
                                        ["type": "array", "items": ["type": "string"]],
                                        ["type": "string"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                [
                    "type": "function",
                    "function": [
                        "name": "WebSearch",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string"],
                                "freshness": [
                                    "type": "string",
                                    "pattern": "^(?:d30)$"
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let changed = Convert.sanitizeToolsSchema(in: &payload)
        #expect(changed == true)

        let tools = (payload["tools"] as? [[String: Any]]) ?? []
        #expect(tools.count == 3)

        // TaskCreate metadata.additionalProperties -> true
        let t1Params = (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        let metaProp = (t1Params?["properties"] as? [String: Any])?["metadata"] as? [String: Any]
        #expect((metaProp?["additionalProperties"] as? Bool) == true)

        // widget_guidelines modules anyOf -> flattened to array
        let t2Params = (tools[1]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        let modulesProp = (t2Params?["properties"] as? [String: Any])?["modules"] as? [String: Any]
        #expect((modulesProp?["type"] as? String) == "array")
        #expect(modulesProp?["anyOf"] == nil)

        // WebSearch freshness pattern stripped
        let t3Params = (tools[2]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        let freshnessProp = (t3Params?["properties"] as? [String: Any])?["freshness"] as? [String: Any]
        #expect((freshnessProp?["type"] as? String) == "string")
        #expect(freshnessProp?["pattern"] == nil)
    }

    @Test("rewriteUpstream normalizes WorkBuddy requests end to end")
    func testRewriteUpstreamWorkBuddyPayload() {
        let input = """
        {
          "model": "system",
          "reasoning_effort": "none",
          "messages": [{"role": "user", "content": "hello"}],
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "TaskCreate",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "metadata": {
                      "type": "object",
                      "additionalProperties": {}
                    }
                  }
                }
              }
            }
          ]
        }
        """
        let headers = ["User-Agent": "WorkBuddy/5.9.3", "X-IDE-Type": "WorkBuddy"]
        let rewritten = Convert.rewriteUpstream(path: "/v1/chat/completions", body: Data(input.utf8), headers: headers)
        let json = (try? JSONSerialization.jsonObject(with: rewritten.body)) as? [String: Any]

        #expect(json?["reasoning_effort"] == nil)
        #expect((json?["stream"] as? Bool) == false)
        let tools = (json?["tools"] as? [[String: Any]]) ?? []
        let params = (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        let meta = (params?["properties"] as? [String: Any])?["metadata"] as? [String: Any]
        #expect((meta?["additionalProperties"] as? Bool) == true)
    }
}
