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
import ballerina/ai.observe;
import ballerina/constraint;
import ballerina/http;
import ballerina/lang.array;
import ballerinax/openrouter;

type ResponseSchema record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

type DocumentContentPart openrouter:ChatMessageContentItemText|openrouter:ChatMessageContentItemImage;

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the " +
    "LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RESULT = "result";
const GET_RESULTS_TOOL = "getResults";
const FUNCTION = "function";
const NO_RELEVANT_RESPONSE_FROM_THE_LLM = "No relevant response from the LLM";

isolated function generateJsonObjectSchema(map<json> schema) returns ResponseSchema {
    string[] supportedMetaDataFields = ["$schema", "$id", "$anchor", "$comment", "title", "description"];

    if schema["type"] == "object" {
        return {schema};
    }

    map<json> updatedSchema = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) is int
        select [key, value];

    updatedSchema["type"] = "object";
    map<json> content = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) !is int
        select [key, value];

    updatedSchema["properties"] = {[RESULT]: content};

    return {schema: updatedSchema, isOriginallyJsonObject: false};
}

isolated function parseResponseAsType(string resp,
        typedesc<anydata> expectedResponseTypedesc, boolean isOriginallyJsonObject) returns anydata|error {
    if !isOriginallyJsonObject {
        map<json> respContent = check resp.fromJsonStringWithType();
        anydata|error result = trap respContent[RESULT].fromJsonWithType(expectedResponseTypedesc);
        if result is error {
            return handleParseResponseError(result);
        }
        return result;
    }

    anydata|error result = resp.fromJsonStringWithType(expectedResponseTypedesc);
    if result is error {
        return handleParseResponseError(result);
    }
    return result;
}

isolated function getExpectedResponseSchema(typedesc<anydata> expectedResponseTypedesc) returns ResponseSchema|ai:Error {
    typedesc<json>|error td = expectedResponseTypedesc.ensureType();
    if td is error {
        return error ai:Error("Unsupported return type for generate(): type must be a subtype of json", td);
    }
    return generateJsonObjectSchema(check generateJsonSchemaForTypedescAsJson(td));
}

isolated function getGetResultsToolChoice() returns openrouter:NamedToolChoice => {
    'type: FUNCTION,
    'function: {
        name: GET_RESULTS_TOOL
    }
};

isolated function getGetResultsTool(map<json> parameters) returns openrouter:ToolDefinitionJson[]|ai:Error {
    return [
        {
            'type: FUNCTION,
            'function: {
                name: GET_RESULTS_TOOL,
                parameters: parameters,
                description: "Tool to call with the response from a large language model (LLM) for a user prompt."
            }
        }
    ];
}

isolated function generateChatCreationContent(ai:Prompt prompt) returns DocumentContentPart[]|ai:Error {
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    DocumentContentPart[] contentParts = [];
    string accumulatedTextContent = "";

    if strings.length() > 0 {
        accumulatedTextContent += strings[0];
    }

    foreach int i in 0 ..< insertions.length() {
        anydata insertion = insertions[i];
        string str = strings[i + 1];

        if insertion is ai:Document|ai:Chunk {
            addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
            accumulatedTextContent = "";
            check addDocumentContentPart(insertion, contentParts);
        } else if insertion is (ai:Document|ai:Chunk)[] {
            addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
            accumulatedTextContent = "";
            foreach ai:Document|ai:Chunk doc in insertion {
                check addDocumentContentPart(doc, contentParts);
            }
        } else {
            accumulatedTextContent += insertion.toString();
        }
        accumulatedTextContent += str;
    }

    addTextContentPart(buildTextContentPart(accumulatedTextContent), contentParts);
    return contentParts;
}

isolated function addDocumentContentPart(ai:Document|ai:Chunk doc, DocumentContentPart[] contentParts) returns ai:Error? {
    if doc is ai:TextDocument|ai:TextChunk {
        return addTextContentPart(buildTextContentPart(doc.content), contentParts);
    } else if doc is ai:ImageDocument {
        return contentParts.push(check buildImageContentPart(doc));
    }
    return error ai:Error("Only text and image documents are supported.");
}

isolated function addTextContentPart(openrouter:ChatMessageContentItemText? contentPart, DocumentContentPart[] contentParts) {
    if contentPart is openrouter:ChatMessageContentItemText {
        return contentParts.push(contentPart);
    }
}

isolated function buildTextContentPart(string content) returns openrouter:ChatMessageContentItemText? {
    if content.length() == 0 {
        return;
    }
    return {'type: "text", text: content};
}

isolated function buildImageContentPart(ai:ImageDocument doc) returns openrouter:ChatMessageContentItemImage|ai:Error =>
    {
    'type: "image_url",
    image_url: {
        url: check buildImageUrl(doc.content, doc.metadata?.mimeType),
        detail: "auto"
    }
};

isolated function buildImageUrl(ai:Url|byte[] content, string? mimeType) returns string|ai:Error {
    if content is ai:Url {
        ai:Url|constraint:Error validationRes = constraint:validate(content);
        if validationRes is error {
            return error(validationRes.message(), validationRes.cause());
        }
        return content;
    }

    return string `data:${mimeType ?: "image/*"};base64,${check getBase64EncodedString(content)}`;
}

isolated function getBase64EncodedString(byte[] content) returns string|ai:Error {
    string|error binaryContent = array:toBase64(content);
    if binaryContent is error {
        return error("Failed to convert byte array to string: " + binaryContent.message() + ", " +
                        binaryContent.detail().toBalString());
    }
    return binaryContent;
}

isolated function handleParseResponseError(error chatResponseError) returns error {
    string msg = chatResponseError.message();
    if msg.includes(JSON_CONVERSION_ERROR) || msg.includes(CONVERSION_ERROR) {
        return error(string `${ERROR_MESSAGE}`, chatResponseError);
    }
    return chatResponseError;
}

isolated function generateLlmResponse(openrouter:Client httpClient, string modelType,
        ai:Prompt prompt, typedesc<json> expectedResponseTypedesc,
        openrouter:SendChatCompletionRequestHeaders requestHeaders) returns anydata|ai:Error {
    observe:GenerateContentSpan span = observe:createGenerateContentSpan(modelType);
    span.addProvider("openrouter");

    DocumentContentPart[] content;
    ResponseSchema responseSchema;
    openrouter:ToolDefinitionJson[] tools;
    do {
        content = check generateChatCreationContent(prompt);
        responseSchema = check getExpectedResponseSchema(expectedResponseTypedesc);
        tools = check getGetResultsTool(responseSchema.schema);
    } on fail ai:Error err {
        span.close(err);
        return err;
    }

    openrouter:ChatGenerationParams request = {
        messages: [
            <openrouter:UserMessage>{
                role: "user",
                content
            }
        ],
        model: modelType,
        tools,
        tool_choice: getGetResultsToolChoice()
    };
    span.addInputMessages(request.messages.toJson());

    openrouter:ChatResponse|error response = httpClient->/chat/completions.post(request, requestHeaders);
    if response is error {
        ai:Error err = buildHttpError(response);
        span.close(err);
        return err;
    }

    span.addResponseId(response.id);
    decimal? inputTokens = response.usage?.prompt_tokens;
    if inputTokens is decimal {
        span.addInputTokenCount(<int>inputTokens);
    }
    decimal? outputTokens = response.usage?.completion_tokens;
    if outputTokens is decimal {
        span.addOutputTokenCount(<int>outputTokens);
    }

    openrouter:ChatResponseChoice[] choices = response.choices;
    if choices.length() == 0 {
        ai:Error err = error("No completion choices");
        span.close(err);
        return err;
    }

    openrouter:AssistantMessage message = choices[0].message;
    openrouter:ChatMessageToolCall[]? toolCalls = message?.tool_calls;
    if toolCalls is () || toolCalls.length() == 0 {
        ai:Error err = error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    openrouter:ChatMessageToolCall tool = toolCalls[0];
    map<json>|error arguments = tool.'function.arguments.fromJsonStringWithType();
    if arguments is error {
        ai:Error err = error ai:LlmInvalidResponseError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
        span.close(err);
        return err;
    }

    anydata|error res = parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc,
            responseSchema.isOriginallyJsonObject);
    if res is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${res.toBalString()}'`);
        span.close(err);
        return err;
    }

    anydata|error result = res.ensureType(expectedResponseTypedesc);
    if result is error {
        ai:Error err = error ai:LlmInvalidGenerationError(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof res).toBalString()}'`);
        span.close(err);
        return err;
    }

    span.addOutputMessages(result.toJson());
    span.addOutputType(observe:JSON);
    span.close();
    return result;
}

isolated function getChatMessageStringContent(ai:Prompt|string prompt) returns string|ai:Error {
    if prompt is string {
        return prompt;
    }
    string[] & readonly strings = prompt.strings;
    anydata[] insertions = prompt.insertions;
    string promptStr = strings[0];
    foreach int i in 0 ..< insertions.length() {
        string str = strings[i + 1];
        anydata insertion = insertions[i];

        if insertion is ai:TextDocument|ai:TextChunk {
            promptStr += insertion.content + " " + str;
            continue;
        }

        if insertion is ai:TextDocument[] {
            foreach ai:TextDocument doc in insertion {
                promptStr += doc.content + " ";
            }
            promptStr += str;
            continue;
        }

        if insertion is ai:TextChunk[] {
            foreach ai:TextChunk doc in insertion {
                promptStr += doc.content + " ";
            }
            promptStr += str;
            continue;
        }

        if insertion is ai:Document {
            return error ai:Error("Only Text Documents are currently supported.");
        }

        promptStr += insertion.toString() + str;
    }
    return promptStr.trim();
}

isolated function buildHttpError(error httpError) returns ai:LlmConnectionError {
    if httpError is http:ApplicationResponseError {
        int statusCode = httpError.detail().statusCode;
        anydata body = httpError.detail().body;
        string bodyStr = body is string ? body : body.toBalString();
        return error ai:LlmConnectionError(
            string `OpenRouter API returned HTTP ${statusCode}: ${bodyStr}`, httpError);
    }
    return error ai:LlmConnectionError(
        string `Failed to connect to OpenRouter: ${httpError.message()}`, httpError);
}

isolated function buildOpenRouterClient(string apiKey, string serviceUrl,
        ConnectionConfig connectionConfig) returns openrouter:Client|ai:Error {
    openrouter:ConnectionConfig connConfig = {
        auth: {token: apiKey},
        httpVersion: connectionConfig.httpVersion,
        http1Settings: connectionConfig.http1Settings ?: {},
        http2Settings: connectionConfig.http2Settings ?: {},
        timeout: connectionConfig.timeout,
        forwarded: connectionConfig.forwarded,
        poolConfig: connectionConfig.poolConfig,
        cache: connectionConfig.cache ?: {},
        compression: connectionConfig.compression,
        circuitBreaker: connectionConfig.circuitBreaker,
        retryConfig: connectionConfig.retryConfig,
        responseLimits: connectionConfig.responseLimits ?: {},
        secureSocket: connectionConfig.secureSocket,
        proxy: connectionConfig.proxy,
        validation: connectionConfig.validation
    };

    openrouter:Client|error 'client = new openrouter:Client(connConfig, serviceUrl);
    if 'client is error {
        return error ai:Error("Failed to initialize HTTP client", 'client);
    }
    return 'client;
}

# Builds the raw HTTP client backing `chatAsStream` and `generateAsStream`.
#
# The generated OpenRouter connector deserializes the full response body, so a streaming
# call cannot go through it and needs a plain `http:Client` instead. This mirrors
# `buildOpenRouterClient` field for field, so a provider configured with a proxy, a custom
# truststore, or tuned pool/retry/limit settings behaves the same whether the caller uses
# `chat` or `chatAsStream`.
#
# + apiKey - The OpenRouter API key
# + serviceUrl - The base URL of the OpenRouter API endpoint
# + connectionConfig - The connection configuration to mirror onto the streaming client
# + return - The streaming HTTP client, or an `ai:Error` if it cannot be initialized
isolated function buildStreamClient(string apiKey, string serviceUrl,
        ConnectionConfig connectionConfig) returns http:Client|ai:Error {
    http:ClientConfiguration streamClientConfig = {
        auth: {token: apiKey},
        httpVersion: connectionConfig.httpVersion,
        http1Settings: connectionConfig.http1Settings ?: {},
        http2Settings: connectionConfig.http2Settings ?: {},
        timeout: connectionConfig.timeout,
        forwarded: connectionConfig.forwarded,
        poolConfig: connectionConfig.poolConfig,
        cache: connectionConfig.cache ?: {},
        compression: connectionConfig.compression,
        circuitBreaker: connectionConfig.circuitBreaker,
        retryConfig: connectionConfig.retryConfig,
        responseLimits: connectionConfig.responseLimits ?: {},
        secureSocket: connectionConfig.secureSocket,
        proxy: connectionConfig.proxy,
        validation: connectionConfig.validation
    };

    http:Client|error streamClient = new (serviceUrl, streamClientConfig);
    if streamClient is error {
        return error ai:Error("Failed to initialize the OpenRouter streaming client", streamClient);
    }
    return streamClient;
}

isolated function convertMessageToJson(ai:ChatMessage[]|ai:ChatMessage messages) returns json|ai:Error {
    if messages is ai:ChatMessage[] {
        json[] result = [];
        foreach ai:ChatMessage msg in messages {
            result.push(check convertMessageToJson(msg));
        }
        return result;
    }
    if messages is ai:ChatUserMessage|ai:ChatSystemMessage {
        return {role: messages.role, content: check getChatMessageStringContent(messages.content), name: messages.name};
    }
    return messages;
}
