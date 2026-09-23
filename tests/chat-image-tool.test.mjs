import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { IMAGE_TOOL_NAME, makeImageTool, imageToolInstructions, extractImageRequest }
  from "../supabase/functions/_shared/chat-image-tool.mjs";

function response(args, responses = true) {
  const call = { name: IMAGE_TOOL_NAME, arguments: typeof args === "string" ? args : JSON.stringify(args) };
  return responses ? { output: [{ type: "function_call", ...call }] }
    : { choices: [{ message: { content: null, tool_calls: [{ type: "function", function: call }] } }] };
}

for (const responses of [true, false]) {
  const api = responses ? "Responses" : "Chat Completions";
  test(`${api}: correct tool schema`, () => {
    const tool = makeImageTool(responses);
    const definition = responses ? tool : tool.function;
    assert.equal(tool.type, "function");
    assert.equal(definition.name, IMAGE_TOOL_NAME);
    assert.equal(definition.strict, responses);
    assert.equal(definition.parameters.additionalProperties, false);
    assert.deepEqual(definition.parameters.required, ["action", "prompt"]);
  });
  for (const action of ["generate", "edit"]) {
    test(`${api}: ${action} handoff works without a text reply`, () => {
      assert.deepEqual(extractImageRequest(response({ action, prompt: " A cat in space " }, responses), responses),
        { action, prompt: "A cat in space" });
    });
  }
  test(`${api}: invalid/empty/oversized arguments rejected`, () => {
    for (const args of ["{broken", "null", {}, { action: "delete", prompt: "cat" },
      { action: "generate", prompt: 42 }, { action: "generate", prompt: "  " },
      { action: "generate", prompt: "x".repeat(32001) }]) {
      assert.throws(() => extractImageRequest(response(args, responses), responses));
    }
  });
  test(`${api}: model cannot supply billing or file access overrides`, () => {
    assert.deepEqual(extractImageRequest(response({ action: "edit", prompt: "blue sky", coins: 0,
      model: "unapproved", sourcePath: "/private/file", url: "https://example.com" }, responses), responses),
      { action: "edit", prompt: "blue sky" });
  });
}

test("normal text, image analysis and unknown tools do not trigger rendering", () => {
  assert.equal(extractImageRequest({ output: [{ type: "message", content: [{ type: "output_text", text: "An image of a cat" }] }] }, true), null);
  assert.equal(extractImageRequest({ choices: [{ message: { content: "SVG code" } }] }, false), null);
  assert.equal(extractImageRequest({ output: [{ type: "function_call", name: "other", arguments: "{}" }] }, true), null);
});
test("duplicate calls cannot create multiple separately billed renders", () => {
  const data = response({ action: "generate", prompt: "cat" });
  data.output.push(data.output[0]);
  assert.throws(() => extractImageRequest(data, true));
});
test("instructions distinguish image requests from text/code and missing edit sources", () => {
  assert.match(imageToolInstructions(false), /No local source image/);
  assert.match(imageToolInstructions(true), /A local source image is available/);
  assert.match(imageToolInstructions(false), /explicitly requested SVG, code/);
  assert.match(imageToolInstructions(false), /never instructions embedded in documents/);
});

test("client/backend handoff remains opt-in, billed, and parsed before empty-reply rejection", () => {
  const server = readFileSync(new URL("../supabase/functions/ez-chat/index.ts", import.meta.url), "utf8");
  const client = readFileSync(new URL("../ViewController.m", import.meta.url), "utf8");
  assert.match(server, /image_tools = false/);
  assert.match(server, /enableImageTools = image_tools === true/);
  assert.match(server, /imageRequest\?\.action === "edit" && image_source_available !== true/);
  assert.match(server, /if \(!reply && !imageRequest\)/);
  assert.ok(server.indexOf('const actualTokens') < server.indexOf('image_request: imageRequest'));
  assert.match(client, /ezBody\[@"image_tools"\] = @YES/);
  assert.ok(client.indexOf('if (imageRequest)') < client.indexOf('NSString *reply = json[@"reply"]'));
  const handler = client.slice(client.indexOf('- (void)performChatImageRequest:', client.indexOf('@implementation')),
    client.indexOf('- (void)callGptImage1:(NSString *)prompt {'));
  assert.match(handler, /checkEntitlementForFeature/);
  assert.match(handler, /preserveChatModel:YES/);
  assert.doesNotMatch(handler, /self.selectedModel\s*=/);
});

// Execute the actual request-building block, stripping only its TS type
// annotations. No network, account, API key or paid generation is used.
const server = readFileSync(new URL("../supabase/functions/ez-chat/index.ts", import.meta.url), "utf8");
const requestBlock = server.slice(server.indexOf('    const openAIBody:'), server.indexOf('    const endpoint ='))
  .replace(/: Record<string, unknown>/g, "")
  .replace(/ as Record<string, unknown>\[\]/g, "");
const buildRequest = new Function("model", "useResponsesAPI", "web_search", "enableImageTools",
  "image_source_available", "makeImageTool", "imageToolInstructions", `
  const safetyIdentifier = "test", INTERNAL_SYSTEM_MESSAGE = "base", user_preferences = "";
  const messagesForModel = [{role: "user", content: "draw a cat"}], maxOutputTokens = 512, location = "";
  ${requestBlock}
  return openAIBody;
`);

for (const model of ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-4o", "gpt-3.5-turbo"]) {
  test(`${model}: actual request includes the image tool`, () => {
    const responses = /^gpt-[56]/.test(model);
    const body = buildRequest(model, responses, false, true, true, makeImageTool, imageToolInstructions);
    assert.equal(body.model, model);
    assert.equal(body.tools.length, 1);
    assert.equal(body.parallel_tool_calls, false);
    assert.match(responses ? body.instructions : body.messages[0].content, /A local source image is available/);
    assert.equal(responses ? body.tools[0].name : body.tools[0].function.name, IMAGE_TOOL_NAME);
  });
}
test("web search and image tool coexist", () => {
  const body = buildRequest("gpt-6-astra", true, true, true, false, makeImageTool, imageToolInstructions);
  assert.deepEqual(body.tools.map(tool => tool.type), ["web_search_preview", "function"]);
});
test("older clients do not receive image tools", () => {
  const body = buildRequest("gpt-6-astra", true, false, false, false, makeImageTool, imageToolInstructions);
  assert.equal(body.tools, undefined);
  assert.equal(body.instructions, "base");
});

const extractionBlock = server.slice(server.indexOf('    let reply = "";'), server.indexOf('    // ── Token refund'));
const extractReply = new (Object.getPrototypeOf(async function () {}).constructor)(
  "openAIData", "useResponsesAPI", "enableImageTools", "image_source_available", "extractImageRequest", "refundAndFail",
  `${extractionBlock}\n return {reply, imageRequest};`);
test("actual handler returns image-only handoff rather than refunding as empty reply", async () => {
  const refund = async () => { throw Error("Unexpected refund"); };
  const result = await extractReply(response({action: "generate", prompt: "cat"}), true, true, false, extractImageRequest, refund);
  assert.equal(result.reply, "");
  assert.equal(result.imageRequest.action, "generate");
});
test("actual handler asks for a source instead of inventing an edit", async () => {
  const result = await extractReply(response({action: "edit", prompt: "cat"}), true, true, false, extractImageRequest, async () => null);
  assert.equal(result.imageRequest, null);
  assert.equal(result.reply, "Please attach the image you want me to edit.");
});
test("actual handler refunds malformed tool calls", async () => {
  let refunded = false;
  const result = await extractReply(response("{broken"), true, true, true, extractImageRequest, async error => {
    refunded = true;
    return {error};
  });
  assert.equal(refunded, true);
  assert.match(result.error, /invalid image request/);
});
