# ytnvim 󰗃
<img width="896" height="466" alt="image" src="https://github.com/user-attachments/assets/14f7f0d9-d484-4c4d-b34f-a4af598857ea" />

O **ytnvim** é um estúdio do YouTube no Neovim dividido em 3 painéis:
1. **Painel Esquerdo (Thumbnail & Metadados)**: Exibe a miniatura em alta definição via Kitty Graphics Protocol do vídeo selecionado, além de título, canal, duração e visualizações.
2. **Painel Central (Vídeos)**: Lista de vídeos do canal ou da pesquisa atual. Ao navegar com `j`/`k`, a thumbnail no painel esquerdo atualiza dinamicamente.
3. **Painel Direito (Canais Salvos)**: Lista dos seus canais favoritos configurados. Ao dar `<Enter>` em um canal, seus vídeos são carregados instantaneamente no painel central.

---

## ⚡ Recursos

- 🖼️ **Painel Esquerdo**: Thumbnail dinâmica em tempo real (compatível com Kitty e tmux), metadados completos (Canal, Duração, Visualizações e Data de Publicação).
- 📋 **Painel Central**: Lista de vídeos com duração, autor e reprodução de vídeo ou áudio via `mpv`.
-  **Painel Direito**: Canais salvos configuráveis no `init.lua`.
- 🔍 **Barra de Busca Integrada**: Suba com `k` no item 1 para focar na barra de busca, dê `<Enter>` para digitar sua pesquisa e `<Enter>` novamente para buscar e retornar à lista de vídeos.
- 📺 **Controle de Qualidade**: Configure a resolução de vídeo desejada (`1080p`, `720p`, `480p`, `best`, etc.).
- 🖼️ **Resolução de Miniatura**: Configure a resolução das thumbnails (`maxresdefault`, `sddefault`, `hqdefault`, `mqdefault`, `default`).
- ⏳ **Carregamento Visual com Spinner**: Animação de spinner direto no item do vídeo e no painel lateral ao iniciar a reprodução, sem popups invasivos.
- ↔️ **Navegação com `h` / `l`**: Mova o foco facilmente entre as janelas (esquerda, centro e direita).
- ↕️ **Navegação com `j` / `k`**: Percorra vídeos e canais.
- ↵ **Ação com `<Enter>`**: Toca o vídeo no painel de vídeos ou carrega o canal no painel de canais.

---

## 📦 Instalação

### Requisitos

- `neovim` >= 0.10.0
- `yt-dlp` (para busca e listagem de canais do YouTube)
- `curl` (para download das miniaturas e metadados de publicação)
- `ffmpeg` (para conversão e redimensionamento das imagens)
- `mpv` (para reprodução de vídeo e áudio)

### Usando `lazy.nvim`

```lua
{
  "DaFi-1/ytnvim",
  config = function()
    require("ytnvim").setup({
      keymap = "<space>a",         -- Atalho global para abrir o ytnvim (ou false para desabilitar)
      volume = 30,                 -- Volume inicial (0 a 100)
      quality = "1080p",           -- Qualidade do vídeo ("1080p", "720p", "480p", "360p", "best")
      thumb_quality = "hqdefault", -- Resolução da thumbnail ("maxresdefault", "sddefault", "hqdefault", "mqdefault", "default")
      search_limit = 20,           -- Quantidade de vídeos por canal ou busca
      width = 124,                 -- Largura fixa em colunas (ou <= 1 para porcentagem da tela)
      height = 26,                 -- Altura fixa em linhas (ou <= 1 para porcentagem da tela)
      channels = {
        { name = "Lofi Girl", url = "https://www.youtube.com/@LofiGirl" },
        { name = "NoCopyrightSounds", url = "https://www.youtube.com/@NoCopyrightSounds" },
        { name = "ChilledCow", url = "https://www.youtube.com/@ChilledCow" },
        { name = "Chillhop Music", url = "https://www.youtube.com/@ChillhopMusic" },
      },
    })
  end,
}
```

---

## ⌨️ Controles

### Navegação Entre Janelas
- `h` / `<Left>`: Mover foco para a janela da esquerda.
- `l` / `<Right>`: Mover foco para a janela da direita.
- `<Tab>` / `<S-Tab>`: Alternar ciclicamente entre as janelas.

### No Painel Central (Vídeos)
| Tecla | Ação |
|---|---|
| `k` (no item 1) | **Pula para a barra de pesquisa** |
| `j` (na barra) | Volta para o item 1 da lista |
| `<CR>` (na barra) | **Abre o prompt para digitar pesquisa** (ao dar Enter busca e foca nos resultados) |
| `<CR>` / `v` (no vídeo) | **Abre e reproduz o VÍDEO** na qualidade configurada no `mpv` |
| `a` | Reproduz **apenas áudio** em segundo plano |
| `<Space>` | Alterna Play / Pause |
| `f` | Alterna tela cheia do vídeo |
| `o` | Alterna modo fixo no topo (on-top) do vídeo |
| `s` / `x` | Para a reprodução (Stop) |
| `+` / `=` | Aumenta o volume (+5%) |
| `-` / `_` | Diminui o volume (-5%) |
| `/` | Fazer uma nova pesquisa livre no YouTube |
| `r` | Recarregar os vídeos do canal atual |
| `y` | Copiar a URL do vídeo para o clipboard |
| `q` / `<Esc>` | Fechar o ytnvim |

### No Painel Direito (Canais Salvos)
| Tecla | Ação |
|---|---|
| `<CR>` | **Carrega os vídeos do canal selecionado** no painel central |
| `a` | Adicionar novo canal interativamente (URL ou @handle) |
| `d` | Remover canal selecionado |
| `h` | Voltar para o painel de vídeos |
| `q` / `<Esc>` | Fechar o ytnvim |
