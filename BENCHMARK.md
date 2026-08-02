# Benchmark dos modelos on-device

Como o catálogo de modelos embarcados (MLX) foi escolhido. Medição sobre uma
gravação real de **36 minutos** — 52 mil caracteres de transcrição, 43 turnos,
~12 mil tokens de prompt. O conteúdo da reunião é privado e não aparece aqui;
ficam a metodologia e os resultados.

Cada modelo foi carregado uma vez e rodado **sozinho, em sequência**, nas duas
tarefas do app — resumo e ponto a ponto — com os prompts de produção,
`temperature = 0` e os limites reais de token (2.048 e 8.192).

## Estrutura: tempos e defeitos mecânicos

| Modelo | Resumo | Ponto a ponto | |
|---|---|---|---|
| Qwen 3.5 2B | 4 s | 10 s | ✅ |
| Gemma 4 E2B | 4 s | 8 s | ✅ |
| Llama 3.2 3B | 10 s | 15 s | ✅ |
| Qwen 3.5 4B | 10 s | 22 s | ✅ |
| Gemma 4 E4B | 6 s | 29 s | ✅ |
| Llama 3.1 8B | 19 s | 30 s | ✅ |
| Nemotron Nano 9B | 26 s | 39 s | ✅ |
| Qwen 3.5 9B | 20 s | 46 s | ✅ |
| Bonsai 27B | 46 s | 78 s | ✅ |
| Bonsai 8B | 16 s | 177 s | ❌ estoura o teto repetindo a mesma frase |
| Nemotron 3 Nano 4B | 11 s | 95 s | ❌ estoura o teto |
| Gemma 4 12B | — | — | não medido (ver limitações) |

Todos os que passam respondem no idioma configurado e nenhum inventa nome de
participante — resultado dos consertos de prompt abaixo.

## Qualidade de conteúdo — leitura das saídas contra a transcrição

Estrutura limpa não significa resumo bom. Cada saída foi lida contra a
transcrição completa e julgada por fidelidade e cobertura:

| Modelo | Veredito |
|---|---|
| **Qwen 3.5 4B** | ⭐ o melhor nas duas tarefas: cobre a reunião inteira, detalhes corretos |
| **Qwen 3.5 9B** | ⭐ mesmo nível, mais detalhe; um artefato pontual (caracteres de outro alfabeto) |
| **Gemma 4 E4B** | ⭐ ponto a ponto excelente do início ao fim; resumos curtos |
| Nemotron Nano 9B | conteúdo fiel, mas quebra o formato pedido (numera seções, adiciona meta-comentário) |
| Bonsai 27B | cobertura completa, porém repete a mesma frase em várias seções |
| Gemma 4 E2B | o mais rápido, mas o ponto a ponto **cobre só os primeiros minutos** da reunião |
| Qwen 3.5 2B | volume igual ao do 4B com conteúdo raso, repetido em círculo |
| Llama 3.1 8B | vago, sem detalhe concreto, seções duplicadas |
| Llama 3.2 3B | **fabrica a estrutura da reunião** — narra perguntas e respostas que não aconteceram |

Flagrantes que nenhuma métrica automática pegou:

- Um modelo transformou uma **piada** dita de passagem num compromisso formal do
  "Next steps".
- Outro inventou **um entregável com prazo** que ninguém combinou, confundindo a
  data da reunião seguinte com um deadline.
- O modelo mais rápido nas métricas entrega um ponto a ponto de 11 seções — todas
  sobre os primeiros minutos; o resto da reunião não existe no texto.
- A reunião tinha **um único compromisso real**. Os modelos bons o capturam
  limpo; os fracos o enterram em listas de tarefas que ninguém assumiu.

## O corte

Ficaram cinco, cada um com um motivo para existir:

| Mantido | Papel |
|---|---|
| Qwen 3.5 4B | padrão — o mais fiel |
| Qwen 3.5 9B | mais detalhe, aceitando esperar |
| Gemma 4 E4B | o melhor ponto a ponto depois dos Qwen |
| Nemotron Nano 9B | opção intermediária fiel (defeito só cosmético) |
| Gemma 4 12B | único multimodal; pendente de medição no app |

| Removido | Motivo |
|---|---|
| Llama 3.2 3B | fabrica estrutura de reunião — desqualificante num app de fidelidade |
| Qwen 3.5 2B | raso e repetitivo nas duas tarefas |
| Llama 3.1 8B | vago e dominado por opções melhores e menores |
| Gemma 4 E2B | ignora a maior parte da reunião no ponto a ponto |
| Bonsai 27B | dominado pelo Qwen 9B: mesmo download, mais lento, qualidade menor |
| Bonsai 8B | ignora o limite do prompt, 3 minutos de texto repetido |
| Nemotron 3 Nano 4B | ignora o limite do prompt, estoura o teto |

Quem já tinha um modelo removido selecionado continua usando — o picker das
configurações mantém o modelo atual mesmo fora do catálogo.

## Lições que moldaram os prompts

O processo derrubou duas suposições e os consertos estão em produção:

1. **Listas sem limite fazem modelo pequeno loopar.** O prompt de ponto a ponto
   dizia "length is not a problem" e o de resumo pedia bullets sem teto; quatro
   modelos repetiam a mesma linha até estourar o teto de tokens. Um número
   explícito ("no máximo 8 bullets", "no máximo 12 partes") consertou três dos
   quatro — os que não consertou saíram do catálogo por defeito próprio. Isolado
   por ablação, com teto de tokens controlado, para separar causa de sintoma.
2. **Pedir agrupamento por pessoa força invenção.** A transcrição só rotula
   `You`/`Others`; exigir "Next steps agrupados por pessoa" fazia os modelos
   catarem nomes ditos em voz alta e atribuir tarefas a quem não as assumiu — e
   um exemplo literal com nome fictício dentro do prompt chegou a virar
   "participante" da reunião. Os prompts agora dizem ao modelo o que ele não
   sabe e mandam escrever a ação sem nome quando o dono não estiver claro.
3. **Instrução de idioma no topo se perde.** Com 12 mil tokens de transcrição
   entre a instrução e a resposta, 5 de 12 modelos respondiam no idioma da
   reunião em vez do configurado. Repetir a instrução depois da transcrição
   zerou o problema.

## Limitações

1. **Não é o binário do app.** Medição via `mlx-lm` (Python) — mesmos kernels
   MLX e mesmos pesos que o `mlx-swift-lm` do app, mas não a mesma pilha.
2. **Gemma 4 12B não foi medido**: é a variante multimodal, que só o runtime
   Swift do app implementa. Segue no catálogo como único multimodal, pendente
   de medição dentro do app.
3. **A avaliação de conteúdo tem um avaliador só** (Claude, lendo as saídas
   contra a transcrição). É julgamento criterioso, não métrica reprodutível.
4. **Uma gravação, uma execução por modelo.** Defeitos que só aparecem em outro
   tipo de reunião não foram capturados — os loops, por exemplo, não existiam
   numa gravação curta e apareceram na de 36 minutos.
