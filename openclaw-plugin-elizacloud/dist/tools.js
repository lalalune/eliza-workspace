import { Type } from "@sinclair/typebox";
export function registerTools(api) {
    const getApiKey = () => {
        if (process.env.ELIZAOS_CLOUD_API_KEY) {
            return process.env.ELIZAOS_CLOUD_API_KEY;
        }
        const providerConfig = api.config?.models?.providers?.["elizacloud"];
        if (providerConfig && typeof providerConfig.apiKey === "string" && !providerConfig.apiKey.includes("*")) {
            return providerConfig.apiKey;
        }
        return null;
    };
    const getBaseUrl = () => {
        return process.env.ELIZAOS_CLOUD_BASE_URL ||
            api.config?.models?.providers?.["elizacloud"]?.baseUrl ||
            "https://www.elizacloud.ai/api/v1";
    };
    const checkConfigText = "Please set the ELIZAOS_CLOUD_API_KEY environment variable. We couldn't find it in the environment or static configuration.";
    api.registerTool({
        name: "eliza_cloud_generate_image",
        label: "Generate Image",
        description: "Generate an image using the ElizaCloud API via DALL-E/Image generation endpoints",
        parameters: Type.Object({
            prompt: Type.String({ description: "Text description of the image to generate" }),
            size: Type.Optional(Type.String({ description: "Size of the generated image, e.g. '1024x1024'" })),
            count: Type.Optional(Type.Number({ description: "Number of images to generate (default: 1)" }))
        }),
        async execute(_toolCallId, args) {
            const apiKey = getApiKey();
            if (!apiKey)
                return { content: [{ type: "text", text: `Error: ${checkConfigText}` }] };
            const prompt = args.prompt;
            const size = args.size ?? "1024x1024";
            const n = args.count ?? 1;
            try {
                const response = await fetch(`${getBaseUrl()}/images/generations`, {
                    method: "POST",
                    headers: {
                        "Authorization": `Bearer ${apiKey}`,
                        "Content-Type": "application/json",
                    },
                    body: JSON.stringify({ prompt, n, size, model: "dall-e-3" })
                });
                if (!response.ok) {
                    const text = await response.text();
                    return { content: [{ type: "text", text: `API Error: ${response.status} ${text}` }] };
                }
                const data = await response.json();
                const images = data.data;
                if (!images || images.length === 0) {
                    return { content: [{ type: "text", text: "No image generated." }] };
                }
                const resultText = images.map((img, i) => `Image ${i + 1}: ${img.url}`).join("\n");
                return {
                    content: [
                        { type: "text", text: `Generated images successfully:\n${resultText}` }
                    ]
                };
            }
            catch (error) {
                return { content: [{ type: "text", text: `Exception during image generation: ${error instanceof Error ? error.message : String(error)}` }] };
            }
        }
    });
    api.registerTool({
        name: "eliza_cloud_text_to_speech",
        label: "Text-to-Speech",
        description: "Convert text to audio speech using the ElizaCloud API",
        parameters: Type.Object({
            text: Type.String({ description: "Text to speak" }),
            voice: Type.Optional(Type.String({ description: "Voice profile to use, e.g. 'nova'" }))
        }),
        async execute(_toolCallId, args) {
            const apiKey = getApiKey();
            if (!apiKey)
                return { content: [{ type: "text", text: `Error: ${checkConfigText}` }] };
            try {
                const text = args.text;
                const voice = args.voice ?? "nova";
                const response = await fetch(`${getBaseUrl()}/audio/speech`, {
                    method: "POST",
                    headers: {
                        "Authorization": `Bearer ${apiKey}`,
                        "Content-Type": "application/json",
                    },
                    body: JSON.stringify({
                        model: "tts-1",
                        input: text,
                        voice: voice
                    })
                });
                if (!response.ok) {
                    const errText = await response.text();
                    return { content: [{ type: "text", text: `API Error: ${response.status} ${errText}` }] };
                }
                return {
                    content: [{ type: "text", text: `Successfully generated text-to-speech audio. Check logs for details.` }]
                };
            }
            catch (error) {
                return { content: [{ type: "text", text: `Exception during TTS: ${error instanceof Error ? error.message : String(error)}` }] };
            }
        }
    });
    api.registerTool({
        name: "eliza_cloud_transcribe_audio",
        label: "Transcribe Audio",
        description: "Transcribe audio from a URL using the ElizaCloud API",
        parameters: Type.Object({
            audioUrl: Type.String({ description: "URL to the audio file to transcribe" })
        }),
        async execute(_toolCallId, args) {
            const apiKey = getApiKey();
            if (!apiKey)
                return { content: [{ type: "text", text: `Error: ${checkConfigText}` }] };
            try {
                const audioUrl = args.audioUrl;
                const audioRes = await fetch(audioUrl);
                if (!audioRes.ok) {
                    return { content: [{ type: "text", text: `Could not fetch audio from URL: ${audioRes.status}` }] };
                }
                const arrayBuffer = await audioRes.arrayBuffer();
                const formData = new FormData();
                formData.append("file", new Blob([arrayBuffer]), "audio.ogg"); // assume ogg or just binary
                formData.append("model", "whisper-1");
                const response = await fetch(`${getBaseUrl()}/audio/transcriptions`, {
                    method: "POST",
                    headers: {
                        "Authorization": `Bearer ${apiKey}`,
                    },
                    body: formData
                });
                if (!response.ok) {
                    const rt = await response.text();
                    return { content: [{ type: "text", text: `Transcription API Error: ${response.status} ${rt}` }] };
                }
                const data = await response.json();
                return {
                    content: [{ type: "text", text: `Transcription complete:\n${data.text}` }]
                };
            }
            catch (error) {
                return { content: [{ type: "text", text: `Exception during transcription: ${error instanceof Error ? error.message : String(error)}` }] };
            }
        }
    });
}
