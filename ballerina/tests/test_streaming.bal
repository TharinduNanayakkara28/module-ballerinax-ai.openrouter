// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;

const SSE_BASE_URL = "http://localhost:8082/sse";

isolated function streamingProvider(string scenario) returns ModelProvider|ai:Error =>
    new (API_KEY, "openai/gpt-5", string `${SSE_BASE_URL}/${scenario}`);

// Collects the text of a chunk stream, so a test asserts on the assembled answer rather
// than on chunk bookkeeping.
isolated function collectContent(stream<ai:ChatMessageChunk, ai:Error?> chunks) returns string|ai:Error {
    string content = "";
    while true {
        record {|ai:ChatMessageChunk value;|}|ai:Error? next = chunks.next();
        if next is () {
            return content;
        }
        if next is ai:Error {
            return next;
        }
        content += next.value.content ?: "";
    }
}

@test:Config
function testChatStreamAssemblesText() returns error? {
    ModelProvider provider = check streamingProvider("text");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});

    string content = "";
    ai:FinishReason? finishReason = ();
    int chunkCount = 0;

    check from ai:ChatMessageChunk chunk in chunks
        do {
            chunkCount += 1;
            content += chunk.content ?: "";
            ai:FinishReason? reason = chunk.finishReason;
            if reason is ai:FinishReason {
                finishReason = reason;
            }
        };

    test:assertEquals(content, "Hello world");
    test:assertEquals(finishReason, ai:STOP);
    test:assertEquals(chunkCount, 3, "The [DONE] sentinel and the usage-only chunk must not surface as chunks");
}

@test:Config
function testChatStreamSetsRoleOnEveryChunk() returns error? {
    ModelProvider provider = check streamingProvider("text");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});

    int chunkCount = 0;
    check from ai:ChatMessageChunk chunk in chunks
        do {
            chunkCount += 1;
            test:assertEquals(chunk.role, ai:ASSISTANT, "role must be set on every chunk");
        };
    test:assertTrue(chunkCount > 1, "This scenario must stream more than one chunk");
}

@test:Config
function testChatStreamCarriesId() returns error? {
    ModelProvider provider = check streamingProvider("text");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});
    record {|ai:ChatMessageChunk value;|}|ai:Error? first = chunks.next();
    if first !is record {|ai:ChatMessageChunk value;|} {
        test:assertFail("Expected a first chunk");
    }
    test:assertEquals(first.value?.id, "gen-1");
    test:assertEquals(first.value.role, ai:ASSISTANT);
    check chunks.close();
}

// Regression test for the leaner envelopes some upstream providers send: only `choices`
// is guaranteed, so requiring `id`/`object`/`created`/`model` would drop the whole chunk.
@test:Config
function testChatStreamAcceptsMinimalEnvelope() returns error? {
    ModelProvider provider = check streamingProvider("minimal");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});
    test:assertEquals(check collectContent(chunks), "Lean envelope");
}

@test:Config
function testChatStreamAccumulatesToolCallFragments() returns error? {
    ModelProvider provider = check streamingProvider("tools");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});

    map<string> names = {};
    map<string> arguments = {};
    map<string> ids = {};
    ai:FinishReason? finishReason = ();

    check from ai:ChatMessageChunk chunk in chunks
        do {
            test:assertEquals(chunk.role, ai:ASSISTANT, "role must be set on every chunk");
            ai:FinishReason? reason = chunk.finishReason;
            if reason is ai:FinishReason {
                finishReason = reason;
            }
            ai:ToolCallChunk[]? toolCalls = chunk.toolCalls;
            if toolCalls is ai:ToolCallChunk[] {
                foreach ai:ToolCallChunk toolCall in toolCalls {
                    string key = toolCall.index.toString();
                    string? id = toolCall?.id;
                    if id is string {
                        ids[key] = id;
                    }
                    string? name = toolCall?.name;
                    if name is string {
                        names[key] = name;
                    }
                    arguments[key] = (arguments[key] ?: "") + (toolCall?.arguments ?: "");
                }
            }
        };

    test:assertEquals(finishReason, ai:TOOL_CALLS);
    test:assertEquals(ids, {"0": "call_a", "1": "call_b"});
    test:assertEquals(names, {"0": "getWeather", "1": "getTime"});
    // Fragments of call 0 arrive either side of call 1, so they must be correlated by index.
    test:assertEquals(arguments, {"0": string `{"city":"Colombo"}`, "1": "{}"});
}

@test:Config
function testChatStreamExposesReasoning() returns error? {
    ModelProvider provider = check streamingProvider("reasoning");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "What is 6 times 7?"});

    string reasoning = "";
    string content = "";
    check from ai:ChatMessageChunk chunk in chunks
        do {
            reasoning += chunk.reasoning ?: "";
            content += chunk.content ?: "";
        };

    test:assertEquals(reasoning, "Let me think about it");
    test:assertEquals(content, "42");
}

// OpenRouter normalizes upstream failures to a finish reason of "error", which is outside
// the `ai:FinishReason` set; it must map to `()` rather than failing the stream. A chunk
// whose only content is that unrecognized reason carries nothing mappable at all, so it is
// skipped entirely rather than surfacing as an empty chunk.
@test:Config
function testChatStreamMapsUnknownFinishReasonToNil() returns error? {
    ModelProvider provider = check streamingProvider("unknownfinish");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});

    string content = "";
    check from ai:ChatMessageChunk chunk in chunks
        do {
            content += chunk.content ?: "";
            test:assertEquals(chunk.finishReason, (), "An unrecognized finish reason must map to ()");
        };
    test:assertEquals(content, "Partial");
}

@test:Config
function testChatStreamSkipsKeepAliveFrames() returns error? {
    ModelProvider provider = check streamingProvider("keepalive");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});
    test:assertEquals(check collectContent(chunks), "After keep-alive");
}

// A generation cut short must surface as an error. Skipping the error frame would hand the
// caller "Partial" as though it were the whole answer.
@test:Config
function testChatStreamSurfacesMidStreamError() returns error? {
    ModelProvider provider = check streamingProvider("midstreamerror");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});

    string|ai:Error content = collectContent(chunks);
    if content !is ai:Error {
        test:assertFail(string `Expected a mid-stream error, got "${content}"`);
    }
    test:assertTrue(content.message().includes("Rate limit exceeded"),
            string `Expected the upstream message, got "${content.message()}"`);
}

@test:Config
function testChatStreamSurfacesMalformedFrame() returns error? {
    ModelProvider provider = check streamingProvider("malformed");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});

    string|ai:Error content = collectContent(chunks);
    if content !is ai:Error {
        test:assertFail(string `Expected a malformed-frame error, got "${content}"`);
    }
    test:assertTrue(content is ai:LlmInvalidResponseError,
            "A malformed frame must surface as an ai:LlmInvalidResponseError");
}

// The status code must be read before the SSE stream is opened, or OpenRouter's own message
// is lost and the caller sees only that the stream could not be opened.
@test:Config
function testChatStreamReportsUnauthorized() returns error? {
    ModelProvider provider = check streamingProvider("unauthorized");
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error chunks =
        provider->chatAsStream({role: ai:USER, content: "hi"});
    if chunks !is ai:Error {
        test:assertFail("Expected a 401 to fail the request");
    }
    test:assertTrue(chunks is ai:LlmConnectionError, "A connection failure must surface as an ai:LlmConnectionError");
    test:assertTrue(chunks.message().includes("401"), chunks.message());
    test:assertTrue(chunks.message().includes("No auth credentials found"), chunks.message());
}

@test:Config
function testChatStreamReportsInsufficientCredits() returns error? {
    ModelProvider provider = check streamingProvider("insufficientcredits");
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error chunks =
        provider->chatAsStream({role: ai:USER, content: "hi"});
    if chunks !is ai:Error {
        test:assertFail("Expected a 402 to fail the request");
    }
    test:assertTrue(chunks.message().includes("Insufficient credits"), chunks.message());
}

@test:Config
function testChatStreamReportsPlainTextErrorBody() returns error? {
    ModelProvider provider = check streamingProvider("plaintexterror");
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error chunks =
        provider->chatAsStream({role: ai:USER, content: "hi"});
    if chunks !is ai:Error {
        test:assertFail("Expected a 502 to fail the request");
    }
    test:assertTrue(chunks.message().includes("upstream provider unavailable"), chunks.message());
}

@test:Config
function testChatStreamSendsAttributionHeaders() returns error? {
    ModelProvider provider = check new (API_KEY, "openai/gpt-5", string `${SSE_BASE_URL}/attribution`,
            siteUrl = "https://example.com", siteName = "Example App");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});
    _ = check collectContent(chunks);
}

@test:Config
function testGenerateAsStreamYieldsTextFragments() returns error? {
    ModelProvider provider = check streamingProvider("text");
    stream<string, ai:Error?> fragments = check provider->generateAsStream(`Say hello`);

    string[] collected = [];
    check from string fragment in fragments
        do {
            collected.push(fragment);
        };

    // Only non-empty content fragments are yielded; the finish-reason and usage-only
    // chunks carry no text and must be skipped rather than emitted as "".
    test:assertEquals(collected, ["Hello", " world"]);
}

// The stream is closable part-way through, which is what an early `break` in a consumer does.
@test:Config
function testChatStreamCloseIsIdempotent() returns error? {
    ModelProvider provider = check streamingProvider("text");
    stream<ai:ChatMessageChunk, ai:Error?> chunks =
        check provider->chatAsStream({role: ai:USER, content: "hi"});
    record {|ai:ChatMessageChunk value;|}|ai:Error? first = chunks.next();
    test:assertTrue(first is record {|ai:ChatMessageChunk value;|});
    check chunks.close();
    check chunks.close();
}
