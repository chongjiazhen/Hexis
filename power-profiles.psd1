#
# power-profiles.psd1 - canonical ECO/PRIME store.
# AUTO-WRITTEN by hexis-launcher.ps1 on 2026-05-16 17:29. Still hand-editable;
# the launcher's Apply overwrites this file. See .local-notes/power-modes.md.
#
@{
    LlamaServer = 'C:\llama.cpp-cuda\llama-server.exe'
    PgDsnBase   = 'postgresql://hexis_user:hexis_password@127.0.0.1:43815'
    DockerHost  = 'host.docker.internal'
    Provider    = 'openai_compatible'
    ApiKeyEnv   = 'OPENAI_API_KEY'
    Nano  = @{ Alias = 'nano-imp-1b'; Repo = 'SicariusSicariiStuff/Nano_Imp_1B_GGUF:Q6_K'; Port = 8082 }
    Embed = @{ Port = 8081 }
    Characters = @(
        @{ Name='Sam'; Db='hexis_memory'; Prime=@{ Tier='gpu'; Alias='hexis-vesper-12b-i1-q6-k'; Path='C:\Users\User\.cache\huggingface\hub\models--mradermacher--Hexis-Vesper-12B-i1-GGUF\snapshots\22e741178bdcf61bf08f98f41df93ac595947c08\Hexis-Vesper-12B.i1-Q6_K.gguf'; Port=8080 } }
        @{ Name='Baymax'; Db='hexis_baymax'; Prime=@{ Tier='gpu'; Alias='qwen2-5-3b-instruct-q6-k-l'; Path='C:\Users\User\.cache\huggingface\hub\models--bartowski--Qwen2.5-3B-Instruct-GGUF\snapshots\f302c64a2269a69fb27b2f9473b362f5bb8e78d8\Qwen2.5-3B-Instruct-Q6_K_L.gguf'; Port=8083 } }
        @{ Name='Rocky'; Db='hexis_rocky'; Prime=@{ Tier='nano'; Alias='nano-imp-1b'; Port=8082 } }
        @{ Name='TARS'; Db='hexis_tars'; Prime=@{ Tier='nano'; Alias='nano-imp-1b'; Port=8082 } }
        @{ Name='Warden'; Db='hexis_warden'; Prime=@{ Tier='gpu'; Alias='qwen3-6-35b-a3b-uncensored-heretic-i1-iq3-xxs'; Path='C:\Users\User\.cache\huggingface\hub\models--mradermacher--Qwen3.6-35B-A3B-uncensored-heretic-i1-GGUF\snapshots\97c91a931dbfd582487e8866bd129a2e8765051d\Qwen3.6-35B-A3B-uncensored-heretic.i1-IQ3_XXS.gguf'; Port=8086 } }
    )
}
