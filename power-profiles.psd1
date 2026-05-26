#
# power-profiles.psd1 - canonical ECO/PRIME store.
# AUTO-WRITTEN by hexis-launcher.ps1 on 2026-05-22 23:45. Hand-editable;
# the launcher's Apply overwrites this file (the GUI is just another editor
# of the same store). See .local-notes/power-modes.md.
#
@{
    LlamaServer = 'C:\llama.cpp-cuda\llama-server.exe'
    PgDsnBase   = 'postgresql://hexis_user:hexis_password@127.0.0.1:43815'
    DockerHost  = 'host.docker.internal'
    Provider    = 'openai_compatible'
    ApiKeyEnv   = 'OPENAI_API_KEY'
    Nano  = @{ Alias = 'nano-imp-1b'; Repo = 'SicariusSicariiStuff/Nano_Imp_1B_GGUF:Q6_K'; Port = 8082 }
    Embed = @{ Port = 8081 }

    # --- Single GPU slot -------------------------------------------------
    # 16 GB VRAM = exactly one ~13 GB model resident. ALL gpu-tier characters
    # share ONE llama-server on BigPort serving ActiveBig; the persona is
    # applied by Hexis at the conversation layer, not by the weights. Switch
    # model = change ActiveBig + re-run set-power-mode prime. NOT a mode.
    BigPort   = 8080
    ActiveBig = 'q36'
    # BigModels values are bare key pointers (@{}). The KEY is the
    # C:\llm-serve\models.json short key; set-power-mode.ps1 resolves
    # alias + gguf path + serve tuning from that single registry. A key
    # with no models.json entry hard-fails cleanly if set as ActiveBig.
    BigModels = @{
        'ablx' = @{}
        'cydonia' = @{}
        'q36' = @{}
    }

    # gpu-tier characters all resolve to ActiveBig on BigPort (shared server).
    # nano-tier characters use the always-on CPU nano (:8082).
    Characters = @(
    )
}
