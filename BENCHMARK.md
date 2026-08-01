# Benchmark dos modelos on-device

Medição de todos os modelos do catálogo embarcado (MLX) com uma carga real:
a gravação **Inovation Hour de 31/07/2026, 36 minutos** — 52.249 caracteres,
43 turnos, **12.174 tokens de prompt**.

Cada modelo rodou **sozinho e em sequência**, com o mesmo prompt de resumo do
app, `temperature = 0`, `max_tokens = 8192` — a mesma configuração que o Zeca usa.

## Resultado

| Modelo | Idioma | Prompt | Geração | Total | Saída | Veredito |
|---|---|---:|---:|---:|---:|---|
| **Qwen 3.5 4B** | português | 2.141 t/s | 85 t/s | **11,7 s** | 2.292 ch | ✅ o mais completo em português |
| **Qwen 3.5 2B** | português | 5.651 t/s | 185 t/s | **4,4 s** | 1.920 ch | ✅ disparado o mais rápido |
| **Bonsai 8B** | português | 1.253 t/s | 58 t/s | 17,9 s | 1.850 ch | ✅ sólido |
| **Nemotron 3 Nano 4B** | português | 1.662 t/s | 102 t/s | 9,9 s | 1.105 ch | ✅ rápido, resumo curto |
| **Nemotron Nano 9B** | português | 774 t/s | 49 t/s | 24,9 s | 1.842 ch | ✅ lento |
| Qwen 3.5 9B | **inglês** | 1.258 t/s | 42 t/s | 18,6 s | 1.926 ch | ⚠️ ignorou o idioma |
| Llama 3.1 8B | **inglês** | 1.195 t/s | 46 t/s | 14,1 s | 906 ch | ⚠️ idioma + resumo raso |
| Bonsai 27B | **inglês** | 382 t/s | 28 t/s | 45,5 s | 1.998 ch | ⚠️ o mais lento de todos |
| Gemma 4 E4B | **inglês** | 3.472 t/s | 72 t/s | 5,6 s | 672 ch | ⚠️ saída mínima |
| Gemma 4 E2B | português | 8.064 t/s | 124 t/s | 68,0 s | 33.349 ch | ❌ **entrou em loop** |
| Llama 3.2 3B | **inglês** | 2.762 t/s | 70 t/s | 121,5 s | 40.104 ch | ❌ **entrou em loop** |
| Gemma 4 12B | — | — | — | — | — | não medido (ver limitações) |

`t/s` = tokens por segundo **nesta máquina**. O número absoluto muda com o
hardware; a ordem entre os modelos, não.

## Os dois que quebram

**Gemma 4 E2B** e **Llama 3.2 3B** não terminam: batem no teto de 8.192 tokens
repetindo a mesma linha até o limite. O Gemma repetiu um único bullet **400
vezes**; o Llama repetiu o mesmo bloco de nomes **47 vezes**.

```
- Discutir a facilidade de uso de ferramentas de captura de conteúdo da web.
- Discutir a facilidade de uso de ferramentas de captura de conteúdo da web.
- Discutir a facilidade de uso de ferramentas de captura de conteúdo da web.   (×400)
```

Não é lentidão: são 68 s e 121 s produzindo lixo. É a pior experiência possível
no app — o usuário espera dois minutos e recebe um arquivo de 40 mil caracteres
inútil. Ambos foram para o fim do catálogo com o defeito escrito no rótulo.

Os dois haviam passado no teste com uma reunião curta. **O loop só aparece com
contexto longo** — que é exatamente o caso de uso real.

## O idioma não é estável

O achado mais importante, e o que invalida a conclusão do teste anterior:
**a obediência ao idioma configurado muda conforme o tamanho da reunião.**

| Modelo | Reunião curta (3k tokens) | Reunião de 36 min (12k tokens) |
|---|---|---|
| Qwen 3.5 9B | português | **inglês** |
| Bonsai 27B | português | **inglês** |
| Llama 3.1 8B | português | **inglês** |
| Nemotron 3 Nano 4B | inglês | **português** |
| Nemotron Nano 9B | inglês | **português** |

Cinco dos doze trocaram de comportamento entre as duas cargas. Só quatro
acertaram o português nas duas: **Qwen 3.5 4B, Qwen 3.5 2B, Bonsai 8B** e
Gemma 4 E2B (que em compensação entra em loop). Consistentes em errar:
Llama 3.2 3B e Gemma 4 E4B.

A leitura prática: com modelo pequeno rodando local, a instrução de idioma no
prompt é uma sugestão, não uma garantia. Os rótulos do catálogo refletem o
comportamento na carga pesada, que é o caso real.

## O que processar 12 mil tokens custa

Numa reunião curta o tempo é quase todo geração. Aqui o **processamento do
prompt** vira metade do custo:

- Bonsai 27B lê a transcrição a 382 t/s → **32 dos 45 segundos** são só leitura,
  antes da primeira palavra sair.
- Qwen 3.5 2B lê a 5.651 t/s → 2 segundos, e ainda escreve o resumo em 2.

Ou seja: a velocidade de geração sozinha engana. O Gemma 4 E4B gera a 72 t/s
(mediano) mas entrega em 5,6 s porque lê o prompt rápido e escreve pouco.

## Recomendação

**Qwen 3.5 4B** continua o padrão certo: português consistente nas duas cargas,
resumo mais completo de todos (2.292 caracteres), 11,7 s para uma reunião de
36 minutos.

Para máquina apertada ou pressa, **Qwen 3.5 2B**: 4,4 s, português, e um resumo
praticamente do mesmo tamanho do 4B com 1,75 GB de download.

## Limitações desta medição

Quatro coisas para não confiar demais nos números:

1. **Não é o binário do app.** Rodei via `mlx-lm` 0.31.3 em Python — mesmos
   kernels MLX e mesmos pesos quantizados que o `mlx-swift-lm` do Zeca, mas não
   é a mesma pilha. Os tempos devem bater de perto, não exatamente.
2. **Gemma 4 12B não foi medido.** É a variante multimodal (`gemma4_unified`,
   com torre de visão e áudio); o `mlx-lm` do Python só implementa a variante de
   texto e rejeita os pesos de visão. O Swift do app implementa a unificada, e o
   modelo funciona lá. Não filtrei pesos para forçar um número, porque isso
   mediria um modelo diferente do que o app carrega.
3. **Memória não está na tabela.** O `peak_memory` do MLX é marca d'água do
   processo inteiro, não por modelo: como rodei os 12 em sequência, o valor só
   sobe e não diz nada sobre cada um. Medir isso direito exige um processo por
   modelo.
4. **Uma execução por modelo.** Sem repetição, sem variância. Com
   `temperature = 0` a saída é determinística, mas o tempo varia com o que mais
   estiver rodando na máquina.
