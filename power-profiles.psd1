#
# power-profiles.psd1 - canonical, hand-editable backing store for ECO/PRIME.
#
# This is the source of truth. set-power-mode.ps1 reads it; the (future) GUI
# launcher WRITES it then calls set-power-mode.ps1. Edit by hand any time.
#
# Concepts:
#   - 4 characters, each = its own Postgres DB on the shared hexis_brain.
#   - "nano" = always-on CPU 1B server (started by start.ps1 on :8082). Never
#     killed by mode switches. Floor every character can fall to.
#   - "embed" :8081 = sacred, never touched.
#   - PRIME = each character on its assigned model (GPU servers armed).
#   - ECO   = every character on nano (GPU servers killed -> VRAM freed).
#             Sam may be overridden at switch time via -SamEndpoint/-SamModel
#             to piggyback a heavy model you already loaded for your own use.
#
# Model refs use llama.cpp -hf form "user/repo:QUANT" (resolves from the HF
# cache at C:\Users\<you>\.cache\huggingface\hub - no redownload on cache hit).
#
@{
    LlamaServer = 'C:\llama.cpp-cuda\llama-server.exe'

    # Postgres reachable from host; workers (in containers) reach llama-servers
    # via host.docker.internal, so DB-stored endpoints use that host.
    PgDsnBase   = 'postgresql://hexis_user:hexis_password@127.0.0.1:43815'
    DockerHost  = 'host.docker.internal'
    Provider    = 'openai_compatible'
    ApiKeyEnv   = 'OPENAI_API_KEY'

    # Always-on CPU nano (managed by start.ps1, not by mode switches).
    Nano = @{
        Alias = 'nano-imp-1b'
        Repo  = 'SicariusSicariiStuff/Nano_Imp_1B_GGUF:Q6_K'
        Port  = 8082
    }

    Embed = @{ Port = 8081 }   # sacred, never touched

    # Per-character config. Db = Postgres database name. Prime = the model this
    # character uses in PRIME. Tier 'gpu' => server armed/killed by mode switch;
    # 'nano' => uses the always-on :8082 (no dedicated server).
    Characters = @(
        @{
            Name = 'Sam';    Db = 'hexis_memory'
            Prime = @{ Tier='gpu';  Alias='hexis-vesper-12b'; Repo='mradermacher/Hexis-Vesper-12B-i1-GGUF:Q6_K'; Port=8080 }
        }
        @{
            Name = 'Baymax'; Db = 'hexis_baymax'
            Prime = @{ Tier='gpu';  Alias='baymax-qwen-3b';   Repo='bartowski/Qwen2.5-3B-Instruct-GGUF:Q6_K_L'; Port=8083 }
        }
        @{
            Name = 'Rocky';  Db = 'hexis_rocky'
            Prime = @{ Tier='nano'; Alias='nano-imp-1b'; Port=8082 }
        }
        @{
            Name = 'TARS';   Db = 'hexis_tars'
            Prime = @{ Tier='nano'; Alias='nano-imp-1b'; Port=8082 }
        }
    )
}
