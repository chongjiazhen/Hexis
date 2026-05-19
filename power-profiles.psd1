#
# power-profiles.psd1 - canonical ECO/PRIME store.
# AUTO-WRITTEN by hexis-launcher.ps1 on 2026-05-17 15:32. Hand-editable;
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
    BigModels = @{
        'cydonia' = @{ Alias = 'cydonia-24b-v4-3-heretic-v4-i1-iq4-xs'; Repo = 'mradermacher/Cydonia-24B-v4.3-heretic-v4-i1-GGUF'; Path = 'C:\Users\User\.cache\huggingface\hub\models--mradermacher--Cydonia-24B-v4.3-heretic-v4-i1-GGUF\snapshots\a0bc01c4723a8a9c4a38f6406a9670b8add0e662\Cydonia-24B-v4.3-heretic-v4.i1-IQ4_XS.gguf' }
        'q36' = @{ Alias = 'qwen3-6-35b-a3b-uncensored-heretic-i1-iq3-xxs'; Path = 'C:\Users\User\.cache\huggingface\hub\models--mradermacher--Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF\snapshots\97c91a931dbfd582487e8866bd129a2e8765051d\Qwen3.6-35B-A3B-uncensored-heretic.i1-IQ3_XXS.gguf' }
        # Retired 2026-05-19 (GGUFs offloaded for disk space, snapshot lifecycle
        # owned by llm-serve): worldsim, pure-soul, sentient-mind, aeon27.
        # Re-add with a live local Path (NOT bare Repo -> Xet-hang wedge) if any
        # returns as an ActiveBig. Remaining on disk: q36 (active), cydonia.
    }

    # gpu-tier characters all resolve to ActiveBig on BigPort (shared server).
    # nano-tier characters use the always-on CPU nano (:8082).
    Characters = @(
        @{ Name='Sam'; Db='hexis_memory'; Prime=@{ Tier='gpu' } }
        @{ Name='Baymax'; Db='hexis_baymax'; Prime=@{ Tier='nano' } }
        @{ Name='Rocky'; Db='hexis_rocky'; Prime=@{ Tier='nano' } }
        @{ Name='TARS'; Db='hexis_tars'; Prime=@{ Tier='nano' } }
        @{ Name='Warden'; Db='hexis_warden'; Prime=@{ Tier='gpu' } }
        @{ Name='ENI'; Db='hexis_eni'; Prime=@{ Tier='gpu' } }
    )
}
