#
# power-profiles.psd1 - canonical ECO/PRIME store.
# Hand-edited 2026-05-19: collapsed to single registry. BigModels values are
# now bare key pointers (@{}); the KEY is the C:\llm-serve\models.json short
# key. set-power-mode.ps1 resolves alias + gguf path + serve tuning from that
# one registry (no more duplicated Alias / frozen snapshot Path here). The
# launcher's Apply still overwrites this file in the same pointer schema.
# See .local-notes/power-modes.md.
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
    ActiveBig = 'ablx'
    # Bare key pointers. KEY = models.json short key; set-power-mode.ps1
    # resolves alias + gguf + tuning from C:\llm-serve\models.json. A key with
    # no models.json entry hard-fails cleanly if set as ActiveBig.
    BigModels = @{
        'ablx'    = @{}   # gemma-4-26B-A4B abliterix V6 (IQ4_XS) - active 2026-05-20
        'q36'     = @{}
        'cydonia' = @{}
        # Retired 2026-05-19 (GGUFs offloaded for disk space, snapshot lifecycle
        # owned by llm-serve): worldsim, pure-soul, sentient-mind, aeon27.
        # Re-add the key here + ensure a live models.json entry (with the gguf
        # in the HF cache) before setting any of them as ActiveBig. Remaining on
        # disk: ablx (active), q36, cydonia.
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
