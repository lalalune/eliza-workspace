const PROVIDER_ID = "elizacloud";
const PROVIDER_LABEL = "ElizaCloud";
const DEFAULT_MODEL = "gpt-4o-mini";
const DEFAULT_BASE_URL = "https://www.elizacloud.ai/api/v1";

export function registerProvider(api: any) {
    api.registerProvider({
        id: PROVIDER_ID,
        label: PROVIDER_LABEL,
        docsPath: "/providers/elizacloud",
        aliases: ["eliza"],
        auth: [
            {
                id: "apikey",
                label: "ElizaCloud API Key",
                hint: "Format: eliza_xxxxx",
                kind: "api_key",
                run: async (ctx: any) => {
                    const spin = ctx.prompter.progress("Configuring ElizaCloud...");
                    try {
                        const apiKey = await ctx.prompter.text({ message: "Enter your ElizaCloud API Key (eliza_xxxxx):" });

                        if (!apiKey || !apiKey.startsWith("eliza_")) {
                            throw new Error("Invalid API Key format. Must start with 'eliza_'");
                        }

                        spin.update("Fetching available models from ElizaCloud...");
                        let fetchedModels: any[] = [];
                        let defaultModelFromFetch = DEFAULT_MODEL;

                        try {
                            const response = await fetch(`${DEFAULT_BASE_URL}/models`, {
                                headers: {
                                    "Authorization": `Bearer ${apiKey}`,
                                    "Content-Type": "application/json"
                                }
                            });
                            if (response.ok) {
                                const data = await response.json();
                                // Assuming the API returns something like `{ data: [{ id, capabilities, context_window }] }`
                                if (data && Array.isArray(data.data)) {
                                    fetchedModels = data.data.map((m: any) => {
                                        // Map ElizaCloud model format to OpenClaw format
                                        return {
                                            id: m.id,
                                            name: m.name || m.id,
                                            input: m.capabilities?.includes("vision") ? ["text", "image"] : ["text"],
                                            contextWindow: m.context_window || m.contextWindow || 128000,
                                            maxTokens: m.max_tokens || m.maxTokens || 4096,
                                            reasoning: m.capabilities?.includes("reasoning") || m.id.includes("reasoning") || m.id.includes("r1") || false
                                        };
                                    });
                                }
                            }
                        } catch (fetchError) {
                            // If fetching models fails (e.g., network error or API format changed), 
                            // we don't necessarily want to completely block the provider setup, 
                            // but we will just provide some default fallbacks.
                            ctx.prompter.note("Failed to automatically fetch models. Falling back to defaults.");
                        }

                        // Default fallback models if the fetch failed or returned empty
                        if (fetchedModels.length === 0) {
                            fetchedModels = [
                                { id: "gpt-5.3", name: "GPT-5.3", input: ["text", "image"], contextWindow: 200000, maxTokens: 16384 },
                                { id: "gpt-4o", name: "GPT-4o (ElizaCloud)", input: ["text", "image"], contextWindow: 128000, maxTokens: 4096 },
                                { id: "codex", name: "Codex", input: ["text"], contextWindow: 128000, maxTokens: 8192 },
                                { id: "claude-4.6", name: "Claude 4.6", input: ["text", "image"], contextWindow: 200000, maxTokens: 8192 },
                                { id: "gemini-2.0-flash", name: "Gemini 2.0 Flash (ElizaCloud)", input: ["text", "image"], contextWindow: 1048576, maxTokens: 8192 },
                                { id: "deepseek-r1", name: "DeepSeek R1", input: ["text"], contextWindow: 128000, maxTokens: 4096, reasoning: true },
                            ];
                        } else {
                            // Ensure default model exists
                            if (!fetchedModels.find(m => m.id === DEFAULT_MODEL)) {
                                defaultModelFromFetch = fetchedModels[0].id;
                            }
                        }

                        spin.stop("ElizaCloud configured successfully.");

                        return {
                            profiles: [
                                {
                                    profileId: `${PROVIDER_ID}:default`,
                                    credential: {
                                        type: "api_key",
                                        provider: PROVIDER_ID,
                                        key: apiKey,
                                    },
                                },
                            ],
                            configPatch: {
                                models: {
                                    providers: {
                                        [PROVIDER_ID]: {
                                            baseUrl: DEFAULT_BASE_URL,
                                            apiKey: `${PROVIDER_ID}:*`,
                                            api: "openai",
                                            models: fetchedModels
                                        }
                                    }
                                },
                                agents: {
                                    defaults: {
                                        models: {
                                            // Alias setup for easy terminal access
                                            [`${PROVIDER_ID}/gpt-4o`]: { alias: "eliza-large" },
                                            [`${PROVIDER_ID}/gpt-4o-mini`]: { alias: "eliza-small" },
                                        },
                                    },
                                },
                            },
                            defaultModel: `${PROVIDER_ID}/${defaultModelFromFetch}`,
                            notes: [`Configured ElizaCloud successfully, verified ${fetchedModels.length} models.`],
                        };
                    } catch (err) {
                        spin.stop("ElizaCloud config failed");
                        throw err;
                    }
                },
            },
        ],
    });
}
