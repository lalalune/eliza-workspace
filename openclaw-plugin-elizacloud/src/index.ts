const emptyPluginConfigSchema = () => ({});
import { registerProvider } from "./provider.js";
import { registerTools } from "./tools.js";

const elizaCloudPlugin = {
    id: "openclaw-plugin-elizacloud",
    name: "ElizaCloud",
    description: "Native OpenClaw extension for ElizaOS Cloud API",
    configSchema: emptyPluginConfigSchema(),
    register(api: any) {
        registerProvider(api);
        registerTools(api);
    }
};

export default elizaCloudPlugin;
