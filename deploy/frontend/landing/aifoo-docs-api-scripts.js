(() => {
  const apiScriptCards = [
    {
      id: "responses",
      title: "OpenAI Responses 文本+视觉",
      endpoint: "POST /v1/responses",
      description: "新一代 OpenAI 接口，适合文本对话、图片理解和流式输出。",
      variants: [
        {
          id: "text",
          title: "纯文本",
          snippets: {
            python: String.raw`import json
import urllib.request

API_URL = "https://aifoo.cc.cd/v1/responses"
API_KEY = "YOUR_API_KEY"

body = {
    "model": "gpt-5.4-mini",
    "stream": True,
    "input": "用中文简单介绍一下 AIFoo。",
}

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        if event.get("type") == "response.output_text.delta":
            print(event.get("delta", ""), end="", flush=True)
        if event.get("type") in ("response.completed", "response.done"):
            break
print()`,
            nodejs: String.raw`const API_URL = "https://aifoo.cc.cd/v1/responses";
const API_KEY = "YOUR_API_KEY";

const body = {
  model: "gpt-5.4-mini",
  stream: true,
  input: "用中文简单介绍一下 AIFoo。",
};

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

const response = await fetch(API_URL, {
  method: "POST",
  headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
  body: JSON.stringify(body),
});
if (!response.ok) throw new Error(await response.text());

for await (const data of readSse(response)) {
  const event = JSON.parse(data);
  if (event.type === "response.output_text.delta") process.stdout.write(event.delta || "");
  if (event.type === "response.completed" || event.type === "response.done") break;
}
process.stdout.write("\n");`
          }
        },
        {
          id: "vision",
          title: "文本+图片",
          snippets: {
            python: String.raw`import json
import urllib.request

API_URL = "https://aifoo.cc.cd/v1/responses"
API_KEY = "YOUR_API_KEY"

body = {
    "model": "gpt-5.4-mini",
    "stream": True,
    "input": [{
        "role": "user",
        "content": [
            {"type": "input_text", "text": "这张图片有什么？请用中文简要描述。"},
            {"type": "input_image", "image_url": "https://aifoo.cc.cd/logo.png"},
        ],
    }],
}

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        if event.get("type") == "response.output_text.delta":
            print(event.get("delta", ""), end="", flush=True)
        if event.get("type") in ("response.completed", "response.done"):
            break
print()`,
            nodejs: String.raw`const API_URL = "https://aifoo.cc.cd/v1/responses";
const API_KEY = "YOUR_API_KEY";

const body = {
  model: "gpt-5.4-mini",
  stream: true,
  input: [{
    role: "user",
    content: [
      { type: "input_text", text: "这张图片有什么？请用中文简要描述。" },
      { type: "input_image", image_url: "https://aifoo.cc.cd/logo.png" },
    ],
  }],
};

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

const response = await fetch(API_URL, {
  method: "POST",
  headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
  body: JSON.stringify(body),
});
if (!response.ok) throw new Error(await response.text());

for await (const data of readSse(response)) {
  const event = JSON.parse(data);
  if (event.type === "response.output_text.delta") process.stdout.write(event.delta || "");
  if (event.type === "response.completed" || event.type === "response.done") break;
}
process.stdout.write("\n");`
          }
        }
      ]
    },
    {
      id: "chat",
      title: "OpenAI Chat Completions 文本+视觉",
      endpoint: "POST /v1/chat/completions",
      description: "兼容传统 OpenAI Chat 格式，适合已有客户端平滑迁移。",
      variants: [
        {
          id: "text",
          title: "纯文本",
          snippets: {
            python: String.raw`import json
import urllib.request

API_URL = "https://aifoo.cc.cd/v1/chat/completions"
API_KEY = "YOUR_API_KEY"

body = {
    "model": "gpt-5.4-mini",
    "stream": True,
    "messages": [{"role": "user", "content": "用中文简单介绍一下 AIFoo。"}],
}

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        chunk = json.loads(data)
        for choice in chunk.get("choices") or []:
            print((choice.get("delta") or {}).get("content", ""), end="", flush=True)
print()`,
            nodejs: String.raw`const API_URL = "https://aifoo.cc.cd/v1/chat/completions";
const API_KEY = "YOUR_API_KEY";

const body = {
  model: "gpt-5.4-mini",
  stream: true,
  messages: [{ role: "user", content: "用中文简单介绍一下 AIFoo。" }],
};

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

const response = await fetch(API_URL, {
  method: "POST",
  headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
  body: JSON.stringify(body),
});
if (!response.ok) throw new Error(await response.text());

for await (const data of readSse(response)) {
  const chunk = JSON.parse(data);
  for (const choice of chunk.choices || []) process.stdout.write(choice.delta?.content || "");
}
process.stdout.write("\n");`
          }
        },
        {
          id: "vision",
          title: "文本+图片",
          snippets: {
            python: String.raw`import json
import urllib.request

API_URL = "https://aifoo.cc.cd/v1/chat/completions"
API_KEY = "YOUR_API_KEY"

body = {
    "model": "gpt-5.4-mini",
    "stream": True,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "这张图片有什么？请用中文简要描述。"},
            {"type": "image_url", "image_url": {"url": "https://aifoo.cc.cd/logo.png"}},
        ],
    }],
}

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        chunk = json.loads(data)
        for choice in chunk.get("choices") or []:
            print((choice.get("delta") or {}).get("content", ""), end="", flush=True)
print()`,
            nodejs: String.raw`const API_URL = "https://aifoo.cc.cd/v1/chat/completions";
const API_KEY = "YOUR_API_KEY";

const body = {
  model: "gpt-5.4-mini",
  stream: true,
  messages: [{
    role: "user",
    content: [
      { type: "text", text: "这张图片有什么？请用中文简要描述。" },
      { type: "image_url", image_url: { url: "https://aifoo.cc.cd/logo.png" } },
    ],
  }],
};

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

const response = await fetch(API_URL, {
  method: "POST",
  headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
  body: JSON.stringify(body),
});
if (!response.ok) throw new Error(await response.text());

for await (const data of readSse(response)) {
  const chunk = JSON.parse(data);
  for (const choice of chunk.choices || []) process.stdout.write(choice.delta?.content || "");
}
process.stdout.write("\n");`
          }
        }
      ]
    },
    {
      id: "anthropic",
      title: "Anthropic Messages 文本+视觉",
      endpoint: "POST /v1/messages",
      description: "Claude / Anthropic Messages 格式；图片模式会先转 base64 再提交。",
      variants: [
        {
          id: "text",
          title: "纯文本",
          snippets: {
            python: String.raw`import json
import urllib.request

API_URL = "https://aifoo.cc.cd/v1/messages"
API_KEY = "YOUR_API_KEY"

body = {
    "model": "claude-sonnet-4-6",
    "max_tokens": 64000,
    "stream": True,
    "messages": [{"role": "user", "content": "用中文简单介绍一下 AIFoo。"}],
}

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        if event.get("type") == "content_block_delta":
            print((event.get("delta") or {}).get("text", ""), end="", flush=True)
        if event.get("type") == "message_stop":
            break
print()`,
            nodejs: String.raw`const API_URL = "https://aifoo.cc.cd/v1/messages";
const API_KEY = "YOUR_API_KEY";

const body = {
  model: "claude-sonnet-4-6",
  max_tokens: 64000,
  stream: true,
  messages: [{ role: "user", content: "用中文简单介绍一下 AIFoo。" }],
};

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

const response = await fetch(API_URL, {
  method: "POST",
  headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
  body: JSON.stringify(body),
});
if (!response.ok) throw new Error(await response.text());

for await (const data of readSse(response)) {
  const event = JSON.parse(data);
  if (event.type === "content_block_delta") process.stdout.write(event.delta?.text || "");
  if (event.type === "message_stop") break;
}
process.stdout.write("\n");`
          }
        },
        {
          id: "vision",
          title: "文本+图片",
          snippets: {
            python: String.raw`import base64
import json
import urllib.request

API_URL = "https://aifoo.cc.cd/v1/messages"
API_KEY = "YOUR_API_KEY"
IMAGE_HEADERS = {"User-Agent": "Mozilla/5.0", "Accept": "image/*,*/*;q=0.8"}

def image_as_base64(url):
    request = urllib.request.Request(url, headers=IMAGE_HEADERS)
    with urllib.request.urlopen(request, timeout=60) as response:
        media_type = response.headers.get("content-type", "image/png").split(";")[0]
        data = base64.b64encode(response.read()).decode("ascii")
    return media_type, data

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

media_type, image_data = image_as_base64("https://aifoo.cc.cd/logo.png")
body = {
    "model": "claude-sonnet-4-6",
    "max_tokens": 64000,
    "stream": True,
    "messages": [{
        "role": "user",
        "content": [
            {"type": "text", "text": "这张图片有什么？请用中文简要描述。"},
            {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": image_data}},
        ],
    }],
}

request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        if event.get("type") == "content_block_delta":
            print((event.get("delta") or {}).get("text", ""), end="", flush=True)
        if event.get("type") == "message_stop":
            break
print()`,
            nodejs: String.raw`const API_URL = "https://aifoo.cc.cd/v1/messages";
const API_KEY = "YOUR_API_KEY";

async function imageAsBase64(url) {
  const response = await fetch(url);
  const mediaType = response.headers.get("content-type")?.split(";")[0] || "image/png";
  const data = Buffer.from(await response.arrayBuffer()).toString("base64");
  return { mediaType, data };
}

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

const image = await imageAsBase64("https://aifoo.cc.cd/logo.png");
const body = {
  model: "claude-sonnet-4-6",
  max_tokens: 64000,
  stream: true,
  messages: [{
    role: "user",
    content: [
      { type: "text", text: "这张图片有什么？请用中文简要描述。" },
      { type: "image", source: { type: "base64", media_type: image.mediaType, data: image.data } },
    ],
  }],
};

const response = await fetch(API_URL, {
  method: "POST",
  headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
  body: JSON.stringify(body),
});
if (!response.ok) throw new Error(await response.text());

for await (const data of readSse(response)) {
  const event = JSON.parse(data);
  if (event.type === "content_block_delta") process.stdout.write(event.delta?.text || "");
  if (event.type === "message_stop") break;
}
process.stdout.write("\n");`
          }
        }
      ]
    },
    {
      id: "imageGeneration",
      title: "gpt-image-2 图片生成",
      endpoint: "POST /v1/images/generations",
      description: "支持文生图，也可以通过 Responses 图片工具接入参考图生成。",
      variants: [
        {
          id: "text",
          title: "文生图",
          snippets: {
            python: String.raw`import base64
import json
import urllib.request
from pathlib import Path

API_URL = "https://aifoo.cc.cd/v1/images/generations"
API_KEY = "YOUR_API_KEY"

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

body = {"model": "gpt-image-2", "prompt": "生成一只太空猫", "n": 1, "size": "1024x1024", "stream": True, "response_format": "b64_json"}
request = urllib.request.Request(
    API_URL,
    data=json.dumps(body).encode("utf-8"),
    method="POST",
    headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"},
)

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        if event.get("type") == "image_generation.partial_image":
            print(".", end="", flush=True)
        if event.get("type") == "image_generation.completed":
            image = event.get("b64_json") or (event.get("data") or [{}])[0].get("b64_json")
            Path("generated-image.png").write_bytes(base64.b64decode(image))
            print("\n图片已保存：generated-image.png")
            break`,
            nodejs: String.raw`const { writeFile } = require("node:fs/promises");
const { join } = require("node:path");

const API_URL = "https://aifoo.cc.cd/v1/images/generations";
const API_KEY = "YOUR_API_KEY";

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

async function main() {
  const response = await fetch(API_URL, {
    method: "POST",
    headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
    body: JSON.stringify({ model: "gpt-image-2", prompt: "生成一只太空猫", n: 1, size: "1024x1024", stream: true, response_format: "b64_json" }),
  });
  if (!response.ok) throw new Error(await response.text());

  for await (const data of readSse(response)) {
    const event = JSON.parse(data);
    if (event.type === "image_generation.partial_image") process.stdout.write(".");
    if (event.type === "image_generation.completed") {
      const image = event.b64_json || event.data?.[0]?.b64_json;
      await writeFile(join(__dirname, "generated-image.png"), Buffer.from(image, "base64"));
      console.log("\n图片已保存：generated-image.png");
      break;
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});`
          }
        },
        {
          id: "vision",
          title: "图生图",
          snippets: {
            python: String.raw`import base64
import json
import urllib.request
from pathlib import Path

API_URL = "https://aifoo.cc.cd/v1/responses"
API_KEY = "YOUR_API_KEY"

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

def image_from_event(event):
    for key in ("b64_json", "base64", "image_base64", "partial_image_b64"):
        if event.get(key):
            return event[key]
    for item in event.get("data") or []:
        image = image_from_event(item)
        if image:
            return image
    for item in (event.get("response") or {}).get("output") or []:
        if item.get("result"):
            return item["result"]
    return (event.get("item") or {}).get("result", "")

body = {
    "model": "gpt-5.4-mini",
    "stream": True,
    "input": [{
        "role": "user",
        "content": [
            {"type": "input_text", "text": "参考这张图，生成一张更精致的 AIFoo 科技风品牌图。"},
            {"type": "input_image", "image_url": "https://aifoo.cc.cd/logo.png"},
        ],
    }],
    "tools": [{"type": "image_generation", "model": "gpt-image-2", "size": "1024x1024", "output_format": "png"}],
    "tool_choice": {"type": "image_generation"},
}
request = urllib.request.Request(API_URL, data=json.dumps(body).encode("utf-8"), method="POST", headers={"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json", "Accept": "text/event-stream"})

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        if event.get("type") in ("image_generation.partial_image", "response.image_generation_call.partial_image"):
            print(".", end="", flush=True)
        image = image_from_event(event)
        if image:
            Path("generated-image.png").write_bytes(base64.b64decode(image))
            print("\n图片已保存：generated-image.png")
            break`,
            nodejs: String.raw`const { writeFile } = require("node:fs/promises");
const { join } = require("node:path");

const API_URL = "https://aifoo.cc.cd/v1/responses";
const API_KEY = "YOUR_API_KEY";

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

function imageFromEvent(event) {
  for (const key of ["b64_json", "base64", "image_base64", "partial_image_b64"]) {
    if (event[key]) return event[key];
  }
  for (const item of event.data || []) {
    const image = imageFromEvent(item);
    if (image) return image;
  }
  for (const item of event.response?.output || []) {
    if (item.result) return item.result;
  }
  return event.item?.result || "";
}

const body = {
  model: "gpt-5.4-mini",
  stream: true,
  input: [{
    role: "user",
    content: [
      { type: "input_text", text: "参考这张图，生成一张更精致的 AIFoo 科技风品牌图。" },
      { type: "input_image", image_url: "https://aifoo.cc.cd/logo.png" },
    ],
  }],
  tools: [{ type: "image_generation", model: "gpt-image-2", size: "1024x1024", output_format: "png" }],
  tool_choice: { type: "image_generation" },
};

async function main() {
  const response = await fetch(API_URL, {
    method: "POST",
    headers: { Authorization: "Bearer " + API_KEY, "Content-Type": "application/json", Accept: "text/event-stream" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(await response.text());

  for await (const data of readSse(response)) {
    const event = JSON.parse(data);
    if (event.type === "image_generation.partial_image" || event.type === "response.image_generation_call.partial_image") process.stdout.write(".");
    const image = imageFromEvent(event);
    if (image) {
      await writeFile(join(__dirname, "generated-image.png"), Buffer.from(image, "base64"));
      console.log("\n图片已保存：generated-image.png");
      break;
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});`
          }
        }
      ]
    },
    {
      id: "imageEdit",
      title: "gpt-image-2 图片编辑",
      endpoint: "POST /v1/images/edits",
      description: "上传图片并按提示修改，通过流式事件保存编辑结果。",
      variants: [
        {
          id: "text",
          title: "编辑图片",
          snippets: {
            python: String.raw`import base64
import json
import mimetypes
import urllib.request
import uuid
from pathlib import Path

API_URL = "https://aifoo.cc.cd/v1/images/edits"
API_KEY = "YOUR_API_KEY"
IMAGE_HEADERS = {"User-Agent": "Mozilla/5.0", "Accept": "image/*,*/*;q=0.8"}

def iter_sse(response):
    buffer = ""
    while chunk := response.read(4096):
        buffer += chunk.decode("utf-8", errors="replace")
        frames = buffer.split("\n\n")
        buffer = frames.pop()
        for frame in frames:
            data = "\n".join(line[5:].strip() for line in frame.splitlines() if line.startswith("data:")).strip()
            if data and data != "[DONE]":
                yield data

def multipart(fields, file_data, file_type):
    boundary = "----aifoo-" + uuid.uuid4().hex
    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    body.extend(f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"source.png\"\r\nContent-Type: {file_type}\r\n\r\n".encode())
    body.extend(file_data)
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    return bytes(body), "multipart/form-data; boundary=" + boundary

image_request = urllib.request.Request("https://aifoo.cc.cd/logo.png", headers=IMAGE_HEADERS)
with urllib.request.urlopen(image_request, timeout=60) as image_response:
    image_type = image_response.headers.get("content-type", "").split(";")[0] or mimetypes.guess_type("source.png")[0] or "image/png"
    image_data = image_response.read()

body, content_type = multipart(
    {"prompt": "把图片整体颜色更改为蓝色。", "model": "gpt-image-2", "n": "1", "quality": "auto", "size": "1024x1024", "stream": "true", "response_format": "b64_json"},
    image_data,
    image_type,
)
request = urllib.request.Request(API_URL, data=body, method="POST", headers={"Authorization": "Bearer " + API_KEY, "Content-Type": content_type, "Accept": "text/event-stream"})

with urllib.request.urlopen(request, timeout=900) as response:
    for data in iter_sse(response):
        event = json.loads(data)
        image = event.get("b64_json") or ((event.get("data") or [{}])[0]).get("b64_json") or (event.get("item") or {}).get("result")
        if event.get("type") == "image_generation.partial_image":
            print(".", end="", flush=True)
        if image:
            Path("edited-image.png").write_bytes(base64.b64decode(image))
            print("\n图片已保存：edited-image.png")
            break`,
            nodejs: String.raw`const { writeFile } = require("node:fs/promises");
const { join } = require("node:path");

const API_URL = "https://aifoo.cc.cd/v1/images/edits";
const API_KEY = "YOUR_API_KEY";

async function* readSse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const frames = buffer.split(/\r?\n\r?\n/);
    buffer = frames.pop() || "";
    for (const frame of frames) {
      const data = frame.split(/\r?\n/).filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
      if (data && data !== "[DONE]") yield data;
    }
  }
}

async function main() {
  const source = await fetch("https://aifoo.cc.cd/logo.png");
  const form = new FormData();
  form.append("image", new File([await source.arrayBuffer()], "source.png", { type: source.headers.get("content-type") || "image/png" }));
  form.append("prompt", "把图片整体颜色更改为蓝色。");
  form.append("model", "gpt-image-2");
  form.append("n", "1");
  form.append("quality", "auto");
  form.append("size", "1024x1024");
  form.append("stream", "true");
  form.append("response_format", "b64_json");

  const response = await fetch(API_URL, { method: "POST", headers: { Authorization: "Bearer " + API_KEY, Accept: "text/event-stream" }, body: form });
  if (!response.ok) throw new Error(await response.text());

  for await (const data of readSse(response)) {
    const event = JSON.parse(data);
    const image = event.b64_json || event.data?.[0]?.b64_json || event.item?.result;
    if (event.type === "image_generation.partial_image") process.stdout.write(".");
    if (image) {
      await writeFile(join(__dirname, "edited-image.png"), Buffer.from(image, "base64"));
      console.log("\n图片已保存：edited-image.png");
      break;
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});`
          }
        }
      ]
    }
  ];

  const escapeHtml = (value) => value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");

  window.initializeAifooApiScripts = () => {
    const root = document.getElementById("api-script-cards");
    if (!root || root.dataset.apiScriptsReady === "true") return;

    root.dataset.apiScriptsReady = "true";
    let activeFilter = "responses";
    const filterCards = document.querySelectorAll("[data-api-filter]");

    const state = Object.fromEntries(apiScriptCards.map((card) => [card.id, {
      variant: card.variants[0].id,
      language: "python"
    }]));

    const render = () => {
      const visibleCards = apiScriptCards.filter((card) => {
        if (activeFilter === "images") return card.id === "imageGeneration" || card.id === "imageEdit";
        return card.id === activeFilter;
      });

      root.innerHTML = visibleCards.map((card) => {
        const current = state[card.id];
        const variant = card.variants.find((item) => item.id === current.variant) || card.variants[0];
        const snippet = variant.snippets[current.language];
        const label = current.language === "python" ? "PYTHON" : "NODE.JS";
        const codeId = `api-script-code-${card.id}-${variant.id}-${current.language}`;

        return `
          <section class="api-script-card">
            <div class="api-script-head">
              <div>
                <p class="api-script-kicker">API SCRIPTS</p>
                <h3>${card.title}</h3>
                <p class="api-script-desc">${card.description}</p>
              </div>
              <span class="api-script-endpoint">${card.endpoint}</span>
            </div>
            <div class="api-script-toolbar">
              <div class="api-toggle-group" aria-label="${card.title} 模式切换">
                ${card.variants.map((item) => `
                  <button
                    class="api-toggle-button${current.variant === item.id ? " is-active" : ""}"
                    type="button"
                    data-api-card="${card.id}"
                    data-api-variant="${item.id}"
                    aria-pressed="${current.variant === item.id ? "true" : "false"}"
                  >${item.title}</button>
                `).join("")}
              </div>
              <div class="api-toggle-group" aria-label="${card.title} 语言切换">
                ${["python", "nodejs"].map((language) => `
                  <button
                    class="api-toggle-button${current.language === language ? " is-active" : ""}"
                    type="button"
                    data-api-card="${card.id}"
                    data-api-language="${language}"
                    aria-pressed="${current.language === language ? "true" : "false"}"
                  >${language === "python" ? "Python" : "Node.js"}</button>
                `).join("")}
              </div>
            </div>
            <div class="api-code-shell">
              <div class="api-code-head">
                <div class="api-code-meta">
                  <span class="api-code-label">${label}</span>
                  <span class="api-code-route">${card.endpoint}</span>
                </div>
                <button class="copy-code api-copy-button" type="button" data-copy-target="${codeId}">复制</button>
              </div>
              <pre><code id="${codeId}">${escapeHtml(snippet)}</code></pre>
            </div>
          </section>
        `;
      }).join("");

      filterCards.forEach((card) => {
        const isActive = card.dataset.apiFilter === activeFilter;
        card.classList.toggle("is-active", isActive);
        card.setAttribute("aria-pressed", String(isActive));
      });
    };

    root.addEventListener("click", (event) => {
      const variantButton = event.target.closest("[data-api-variant]");
      if (variantButton) {
        const { apiCard, apiVariant } = variantButton.dataset;
        if (state[apiCard]) {
          state[apiCard].variant = apiVariant;
          render();
        }
        return;
      }

      const languageButton = event.target.closest("[data-api-language]");
      if (languageButton) {
        const { apiCard, apiLanguage } = languageButton.dataset;
        if (state[apiCard]) {
          state[apiCard].language = apiLanguage;
          render();
        }
        return;
      }
    });

    filterCards.forEach((card) => {
      const activate = () => {
        activeFilter = card.dataset.apiFilter || "responses";
        render();
      };

      card.addEventListener("click", activate);
      card.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          activate();
        }
      });
    });

    render();
  };
})();
