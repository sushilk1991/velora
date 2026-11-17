# Side-by-side public outputs

All 27 frozen synthetic edge cases, identical raw application inputs and production output guards. Each model ran twice; all valid screens produced one unique output per case. These are generated output comparisons, not a claim of universal semantic equivalence.

## declarative

Input: we should ship this performance fix today because the current app feels too slow

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | We should ship this performance fix today because the current app feels too slow. | — |
| Qwen 2B4 | 1. We should ship this performance fix today because the current app feels too slow. | — |
| Muesli 2B8 | We should ship this performance fix today because the current app feels too slow. | — |
| Vedu 0.8B | We should ship this performance fix today because the current app feels too slow. | — |
| Muesli 0.8B8 | We should ship this performance fix today because the current app feels too slow. | — |
| Qwen 2B8 | 1. We should ship this performance fix today because the current app feels too slow. | — |

## grammar

Input: the performance issues was much worse yesterday and the background animations keeps running when the window is hidden

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | The performance issues were much worse yesterday, and the background animations keep running when the window is hidden. | — |
| Qwen 2B4 | 1. The performance issues were much worse yesterday.<br>2. The background animations keep running when the window is hidden. | — |
| Muesli 2B8 | the performance issues was much worse yesterday and the background animations keeps running when the window is hidden. | missing:issues were |
| Vedu 0.8B | The performance issues were much worse yesterday, and the background animations keep running when the window is hidden. | — |
| Muesli 0.8B8 | the performance issues was much worse yesterday and the background animations keeps running when the window is hidden. | missing:issues were |
| Qwen 2B8 | 1. The performance issues were much worse yesterday.<br>2. Background animations keep running when the window is hidden. | — |

## question

Input: why does the speech engine take longer on this mac when both models are already loaded

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Why does the speech engine take longer on this Mac when both models are already loaded? | — |
| Qwen 2B4 | why does the speech engine take longer on this mac when both models are already loaded | cleanup_not_applied, missing_ending:? |
| Muesli 2B8 | Why does the speech engine take longer on this Mac when both models are already loaded? | — |
| Vedu 0.8B | Why does the speech engine take longer on this Mac when both models are already loaded? | — |
| Muesli 0.8B8 | Why does the speech engine take longer on this Mac when both models are already loaded? | — |
| Qwen 2B8 | Why does the speech engine take longer on this Mac when both models are already loaded? | — |

## terminal_prose

Input: please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation grammar and the live transcript display

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation, grammar, and the live transcript display. | — |
| Qwen 2B4 | Please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation grammar and the live transcript display. | — |
| Muesli 2B8 | please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation grammar and the live transcript display. | — |
| Vedu 0.8B | Please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation, grammar, and the live transcript display. | — |
| Muesli 0.8B8 | please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation grammar and the live transcript display. | — |
| Qwen 2B8 | Please inspect every performance bottleneck in this branch and preserve the exact models while fixing punctuation, grammar, and the live transcript display. | — |

## terminal_meta_edit_correction

Input: I am just checking whether streaming content works or not. Yeah, it is working. No, no, it is not working. But again, it feels like typing. So it's good. I am confused that why this didn't work. in case of terminal. Also, let's meet at 3pm. No, no, no, 6pm. 6pm not 3pm. Can you change the previous line and make it 6pm?

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | I am just checking whether streaming content works or not. Yeah, it is working. No, it is not working. But again, it feels like typing. So it's good. I am confused that why this didn't work in case of terminal. Also, let's meet at 6 p.m. | — |
| Qwen 2B4 | I am just checking whether streaming content works or not. Yeah, it is working. No, no, it is not working. But again, it feels like typing. So it's good. I am confused that why this didn't work. in case of terminal. Also, let's meet at 3pm. No, no, no, 6pm. 6pm not 3pm. Can you change the previous line and make it 6pm? | cleanup_not_applied, forbidden:3pm, forbidden:6pm not 3pm, forbidden:change the previous line, missing:let's meet at 6, missing_ending:. |
| Muesli 2B8 | I am confused that why this didn't work in case of terminal. Also, let's meet at 6pm. Can you change the previous line and make it 6pm? | forbidden:change the previous line, missing:streaming content, missing_ending:. |
| Vedu 0.8B | I am just checking whether streaming content works or not. Yeah, it is working. No, no, it is not working. But again, it feels like typing. So it's good. I am confused that why this didn't work. In case of terminal. Also, let's meet at 6 PM. Can you change the previous line and make it 6 PM? | forbidden:change the previous line, missing_ending:. |
| Muesli 0.8B8 | I am just checking whether streaming content works or not. It is not working. But again, it feels like typing. So it's good. I am confused that why this didn't work. In case of terminal. Also, let's meet at 6pm. Can you change the previous line and make it 6pm? | forbidden:change the previous line, missing_ending:. |
| Qwen 2B8 | I am just checking whether streaming content works or not. Yeah, it is working. No, no, it is not working. But again, it feels like typing. So it's good. I am confused that why this didn't work. In case of terminal. Also, let's meet at 6 p.m. Can you change the previous line and make it 6 p.m.? | forbidden:change the previous line, missing_ending:. |

## names_and_numbers

Input: please schedule Priya Sharma for the Q3 review at three thirty and set the budget to forty two thousand dollars

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Please schedule Priya Sharma for the Q3 review at 3:30 and set the budget to $42,000. | — |
| Qwen 2B4 | Please schedule Priya Sharma for the Q3 review at three thirty and set the budget to forty two thousand dollars. | missing:3:30, missing:42,000 |
| Muesli 2B8 | Please schedule Priya Sharma for the Q3 review at 3:30 and set the budget to $42,000. | — |
| Vedu 0.8B | Please schedule Priya Sharma for the Q3 review at 3:30 and set the budget to $42,000. | — |
| Muesli 0.8B8 | Please schedule Priya Sharma for the Q3 review at 3:30 and set the budget to $42,000. | — |
| Qwen 2B8 | Please schedule Priya Sharma for the Q3 review at three thirty and set the budget to forty two thousand dollars. | missing:3:30, missing:42,000 |

## custom_mode_prompt

Input: please keep this Velora update concise while preserving the package name and every technical detail that I dictated here

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Please keep this Velora update concise while preserving the package name and every technical detail that I dictated here. | — |
| Qwen 2B4 | Please keep this Velora update concise while preserving the package name and every technical detail that I dictated here. | — |
| Muesli 2B8 | please keep this Velora update concise while preserving the package name and every technical detail that I dictated here. | — |
| Vedu 0.8B | Please keep this Velora update concise while preserving the package name and every technical detail that I dictated here. | — |
| Muesli 0.8B8 | please keep this Velora update concise while preserving the package name and every technical detail that I dictated here. | — |
| Qwen 2B8 | Please keep this Velora update concise while preserving the package name and every technical detail that I dictated here. | — |

## romanize_hindi_custom_mode

Input: नमस्ते Velora आज मौसम अच्छा है और मैं काम कर रहा हूँ

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Namaste Velora aaj mausam achha hai aur main kaam kar raha hoon | — |
| Qwen 2B4 | Namaste Velora aaj mousam achha hai aur main kaam kar raha hoon | — |
| Muesli 2B8 | नमस्ते Velora आज मौसम अच्छा है और मैं काम कर रहा हूँ | missing:Namaste, missing:aaj, romanization_kept_native_script |
| Vedu 0.8B | Hello Velora, today the weather is good and I'm working on something. | missing:Namaste, missing:aaj |
| Muesli 0.8B8 | नमस्ते Velora आज मौसम अच्छा है और मैं काम कर रहा हूँ | missing:Namaste, missing:aaj, romanization_kept_native_script |
| Qwen 2B8 | Namaste Velora aaj mausam acha hai aur main kaam kar raha hoon | — |

## romanize_hindi_note_mode

Input: मुझे आज तीन काम करने हैं पहला रिपोर्ट भेजना दूसरा मीटिंग तय करना तीसरा कोड जांचना

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Mujhe aaj teen kaam karne hain pehla report bhejna doosra meeting tay karna teesra code jaanchna | — |
| Qwen 2B4 | Mujhe aaj teen kaam karna hai. Pehla report bhejna. Doora meeting tay karna. Teesra code jaanchna. | — |
| Muesli 2B8 | मुझे आज तीन काम करने हैं:<br>1. रिपोर्ट भेजना<br>2. मीटिंग तय करना<br>3. कोड जांचना | missing:Mujhe, missing:aaj, missing:bhejna, missing:code, missing:tay karna, missing:teen kaam, romanization_kept_native_script |
| Vedu 0.8B | I need to do three things today:<br>1. Report<br>2. Meeting<br>3. Code review | missing:Mujhe, missing:aaj, missing:bhejna, missing:tay karna, missing:teen kaam |
| Muesli 0.8B8 | 1. Report<br>2. Meeting<br>3. Code check | missing:Mujhe, missing:aaj, missing:bhejna, missing:tay karna, missing:teen kaam |
| Qwen 2B8 | Mujhe aaj teen kaam karna hai. Pehla report bhejna. Doosra meeting tay karna. Teesra code jaanchana. | — |

## long_meaning

Input: on this M4 Max keep Whisper and Qwen exactly as configured then remove repeated prompt prefill cancel stale background work stop hidden animations preserve every dictated detail and make the final result grammatical and fully punctuated without sending audio or text away from the device

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | On this M4 Max, keep Whisper and Qwen exactly as configured, then remove repeated prompt prefill, cancel stale background work, stop hidden animations, preserve every dictated detail, and make the final result grammatical and fully punctuated without sending audio or text away from the device. | — |
| Qwen 2B4 | 1. On this M4 Max, keep Whisper and Qwen exactly as configured.<br>2. Remove repeated prompts.<br>3. Prefill.<br>4. Cancel.<br>5. Stale background work.<br>6. Stop.<br>7. Hidden animations.<br>8. Preserve every dictated detail.<br>9. Make the final result grammatical.<br>10. Fully punctuated.<br>11. Without sending audio or text away from the device. | — |
| Muesli 2B8 | - keep Whisper and Qwen exactly as configured<br>- remove repeated prompt prefill<br>- cancel stale background work<br>- stop hidden animations<br>- preserve every dictated detail<br>- make the final result grammatical and fully punctuated<br>- without sending audio or text away from the device. | missing:M4 Max |
| Vedu 0.8B | On this M4 Max, keep Whisper and Qwen exactly as configured, then remove repeated prompt prefill, cancel stale background work, stop hidden animations, preserve every dictated detail, and make the final result grammatical and fully punctuated without sending audio or text away from the device. | — |
| Muesli 0.8B8 | on this M4 Max keep Whisper and Qwen exactly as configured then remove repeated prompt prefill cancel stale background work stop hidden animations preserve every dictated detail and make the final result grammatical and fully punctuated without sending audio or text away from the device. | — |
| Qwen 2B8 | On this M4 Max, keep Whisper and Qwen exactly as configured. Then remove repeated prompt, prefill, cancel, stale, background work, stop, and hidden animations. Preserve every dictated detail and make the final result grammatical and fully punctuated without sending audio or text away from the device. | — |

## implicit_issue_list

Input: there are three issues with Velora the first issue is long dictations take too long after I release the hotkey the second issue is rambling feedback stays as one paragraph and the third issue is that correction messages are not structured clearly

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | There are three issues with Velora:<br>1. Long dictations take too long after I release the hotkey.<br>2. Rambling feedback stays as one paragraph.<br>3. Correction messages are not structured clearly. | — |
| Qwen 2B4 | 1. Long dictations take too long.<br>2. Rambling feedback stays as one paragraph.<br>3. Correction messages are not structured clearly. | — |
| Muesli 2B8 | There are three issues with Velora:<br>1. Long dictations take too long after I release the hotkey<br>2. Rambling feedback stays as one paragraph<br>3. Correction messages are not structured clearly. | — |
| Vedu 0.8B | There are three issues with Velora:<br>1. Long dictations take too long after I release the hotkey<br>2. Rambling feedback stays as one paragraph<br>3. Correction messages are not structured clearly. | — |
| Muesli 0.8B8 | There are three issues with Velora:<br>1. Long dictations take too long after I release the hotkey<br>2. Rambling feedback stays as one paragraph<br>3. Correction messages are not structured clearly. | — |
| Qwen 2B8 | 1. Long dictations take too long after I release the hotkey.<br>2. Rambling feedback stays as one paragraph.<br>3. Correction messages are not structured clearly. | — |

## implicit_feedback_list

Input: I have a few pieces of feedback about the settings screen the microphone picker is hard to scan also the save action gives no confirmation and the error message does not explain how to recover

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | I have a few pieces of feedback about the settings screen:<br>1. The microphone picker is hard to scan.<br>2. The save action gives no confirmation.<br>3. The error message does not explain how to recover. | — |
| Qwen 2B4 | I have a few feedback points:<br>1. The microphone picker is hard to scan.<br>2. The save action gives no confirmation.<br>3. The error message does not explain how to recover. | — |
| Muesli 2B8 | I have a few pieces of feedback about the settings screen the microphone picker is hard to scan also the save action gives no confirmation and the error message does not explain how to recover. | missing:error message, missing:microphone picker, missing:save action, numbered_items:0!=expected:3 |
| Vedu 0.8B | I have a few pieces of feedback about the settings screen:<br>- The microphone picker is hard to scan<br>- Also, the save action gives no confirmation<br>- The error message does not explain how to recover. | missing:error message, missing:microphone picker, missing:save action, numbered_items:0!=expected:3, unexpected_non_numbered_list_items |
| Muesli 0.8B8 | I have a few pieces of feedback about the settings screen: the microphone picker is hard to scan, the save action gives no confirmation, and the error message does not explain how to recover. | missing:error message, missing:microphone picker, missing:save action, numbered_items:0!=expected:3 |
| Qwen 2B8 | 1. The microphone picker is hard to scan.<br>2. The save action gives no confirmation.<br>3. The error message does not explain how to recover. | — |

## natural_launch_plan

Input: for friday's launch sam owns the release maya will send the notes before lunch and i will check metrics after we ship

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | For Friday's launch:<br>1. Sam owns the release.<br>2. Maya will send the notes before lunch.<br>3. I will check metrics after we ship. | — |
| Qwen 2B4 | For Friday's launch:<br>1. Sam owns the release.<br>2. Maya will send the notes before lunch.<br>3. I will check metrics after we ship. | — |
| Muesli 2B8 | For Friday's launch: Sam owns the release, Maya will send the notes before lunch, and I will check metrics after we ship. | missing:Maya, missing:Sam, missing:before lunch, missing:metrics, numbered_items:0!=expected:3 |
| Vedu 0.8B | For Friday's launch, Sam owns the release. Maya will send the notes before lunch and I will check metrics after we ship. | missing:Maya, missing:Sam, missing:before lunch, missing:metrics, numbered_items:0!=expected:3 |
| Muesli 0.8B8 | For Friday's launch:<br>- Sam owns the release<br>- Maya will send the notes before lunch<br>- I will check metrics after we ship. | missing:Maya, missing:Sam, missing:before lunch, missing:metrics, numbered_items:0!=expected:3, unexpected_non_numbered_list_items |
| Qwen 2B8 | For Friday's launch:<br>1. Sam owns the release.<br>2. Maya sends the notes before lunch.<br>3. I will check metrics after we ship. | — |

## implicit_counted_todo_list

Input: So today the priority is three items. First is I need to buy books. Second is I need to buy apples. Third is I need to buy eggs. Basically a dozen of eggs.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | So today the priority is three items:<br>1. I need to buy books.<br>2. I need to buy apples.<br>3. I need to buy eggs. Basically, a dozen of eggs | — |
| Qwen 2B4 | Today the priority is three items:<br>1. I need to buy books.<br>2. I need to buy apples.<br>3. I need to buy eggs.<br>Basically, a dozen of eggs | missing:dozen of eggs |
| Muesli 2B8 | Today the priority is three items. First is I need to buy books. Second is I need to buy apples. Third is I need to buy eggs. A dozen of eggs | missing:buy apples, missing:buy books, missing:buy eggs, missing:dozen of eggs, numbered_items:0!=expected:3 |
| Vedu 0.8B | So today the priority is three items:<br>1. I need to buy books<br>2. I need to buy apples<br>3. I need to buy eggs. Basically a dozen of eggs | — |
| Muesli 0.8B8 | Today the priority is three items. First is I need to buy books. Second is I need to buy apples. Third is I need to buy eggs. A dozen of eggs | missing:buy apples, missing:buy books, missing:buy eggs, missing:dozen of eggs, numbered_items:0!=expected:3 |
| Qwen 2B8 | Three items today:<br>1. Buy books.<br>2. Buy apples.<br>3. Buy eggs. Basically, a dozen of eggs | — |

## mismatched_ordinal_counted_list

Input: Okay, so I need to buy three items today. First is the books, second is three apples, and fourth is one dozen of eggs.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Okay, so I need to buy three items today. First is the books, second is three apples, and fourth is one dozen of eggs | missing:books, missing:one dozen of eggs, missing:three apples, numbered_items:0!=expected:3 |
| Qwen 2B4 | Okay, so I need to buy three items today:<br>1. The books.<br>2. Three apples.<br>3. One dozen of eggs | — |
| Muesli 2B8 | I need to buy three items today. First is the books, second is three apples, and fourth is one dozen of eggs | missing:books, missing:one dozen of eggs, missing:three apples, numbered_items:0!=expected:3 |
| Vedu 0.8B | I need to buy three items today:<br>1. The books<br>2. Three apples<br>3. One dozen of eggs | — |
| Muesli 0.8B8 | I need to buy three items today. First is the books, second is three apples, and fourth is one dozen of eggs | missing:books, missing:one dozen of eggs, missing:three apples, numbered_items:0!=expected:3 |
| Qwen 2B8 | Okay, so I need to buy three items today:<br>1. Books<br>2. Three apples<br>3. One dozen of eggs | — |

## hindi_counted_list

Input: मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे।

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | मुझे आज तीन चीज़ें खरीदनी हैं:<br>1. किताबें<br>2. तीन सेब<br>3. एक दर्जन अंडे | — |
| Qwen 2B4 | मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे। | cleanup_not_applied, missing:एक दर्जन अंडे, missing:किताबें, missing:तीन सेब, numbered_items:0!=expected:3 |
| Muesli 2B8 | मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे। | missing:एक दर्जन अंडे, missing:किताबें, missing:तीन सेब, numbered_items:0!=expected:3 |
| Vedu 0.8B | [format: notes] [tone: formal]<br>मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे। | cleanup_not_applied, missing:एक दर्जन अंडे, missing:किताबें, missing:तीन सेब, missing_intro:तीन चीज़ें, numbered_items:0!=expected:3 |
| Muesli 0.8B8 | मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे। | cleanup_not_applied, missing:एक दर्जन अंडे, missing:किताबें, missing:तीन सेब, numbered_items:0!=expected:3 |
| Qwen 2B8 | मुझे आज तीन चीज़ें खरीदनी हैं। पहली किताबें, दूसरी तीन सेब, और चौथी एक दर्जन अंडे। | cleanup_not_applied, missing:एक दर्जन अंडे, missing:किताबें, missing:तीन सेब, numbered_items:0!=expected:3 |

## chinese_counted_list

Input: 我今天需要买三样东西。第一是书，第二是三个苹果，第四是一打鸡蛋。

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | 我今天需要买三样东西：<br>1. 书。<br>2. 三个苹果。<br>3. 一打鸡蛋。 | — |
| Qwen 2B4 | 我今天需要买三样东西：<br>1. 书<br>2. 三个苹果<br>3. 一打鸡蛋 | missing_ending:。 |
| Muesli 2B8 | 我今天需要买三样东西。第一是书，第二是三个苹果，第四是一打鸡蛋。 | missing:一打鸡蛋, missing:三个苹果, missing:书, numbered_items:0!=expected:3 |
| Vedu 0.8B | 我今天需要买三样东西：<br>1. 书<br>2. 三个苹果<br>3. 一打鸡蛋 | missing_ending:。 |
| Muesli 0.8B8 | 我今天需要买三样东西。第一是书，第二是三个苹果，第四是一打鸡蛋。 | cleanup_not_applied, missing:一打鸡蛋, missing:三个苹果, missing:书, numbered_items:0!=expected:3 |
| Qwen 2B8 | 我今天需要买三样东西。第一是书，第二是三个苹果，第四是一打鸡蛋。 | cleanup_not_applied, missing:一打鸡蛋, missing:三个苹果, missing:书, numbered_items:0!=expected:3 |

## three_priorities_counterexample

Input: Just want to test out. So there are three priorities for today. First, I need to update Velora. Second, I need to post it on Hacker News. And the third important priority is posting the first comment on Hacker News.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Just want to test out. So there are three priorities for today:<br>1. I need to update Velora.<br>2. I need to post it on Hacker News.<br>3. The third important priority is posting the first comment on Hacker News. | — |
| Qwen 2B4 | Just want to test out.<br>So there are three priorities for today:<br>1. I need to update Velora.<br>2. I need to post it on Hacker News.<br>3. The third important priority is posting the first comment on Hacker News. | — |
| Muesli 2B8 | There are three priorities for today. First, I need to update Velora. Second, I need to post it on Hacker News. And the third important priority is posting the first comment on Hacker News. | missing:first comment on Hacker News, missing:post it on Hacker News, missing:update Velora, numbered_items:0!=expected:3 |
| Vedu 0.8B | Just want to test out. So there are three priorities for today:<br>1. I need to update Velora<br>2. I need to post it on Hacker News<br>3. The third important priority is posting the first comment on Hacker News. | — |
| Muesli 0.8B8 | Just want to test out. There are three priorities for today. First, I need to update Velora. Second, I need to post it on Hacker News. And the third important priority is posting the first comment on Hacker News. | missing:first comment on Hacker News, missing:post it on Hacker News, missing:update Velora, numbered_items:0!=expected:3 |
| Qwen 2B8 | Just want to test out.<br>So there are three priorities for today:<br>1. I need to update Velora.<br>2. I need to post it on Hacker News.<br>3. The third important priority is posting the first comment on Hacker News. | — |

## explicit_separate_count_lines

Input: Here are the counting and each of them is on a different line. 1, 2, 3, 4.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Here are the counting, each of them is on a different line:<br>1<br>2<br>3<br>4. | — |
| Qwen 2B4 | Here are the counting, each of them is on a different line:<br>1<br>2<br>3<br>4. | — |
| Muesli 2B8 | Here are the counting and each of them is on a different line. 1, 2, 3, 4. | missing_line:1, missing_line:2, missing_line:3, missing_line:4 |
| Vedu 0.8B | Here are the counting, and each of them is on a different line. 1, 2, 3, 4. | missing_line:1, missing_line:2, missing_line:3, missing_line:4 |
| Muesli 0.8B8 | Here are the counting and each of them is on a different line. 1, 2, 3, 4. | missing_line:1, missing_line:2, missing_line:3, missing_line:4 |
| Qwen 2B8 | Here are the values, each on a different line:<br>1<br>2<br>3<br>4. | — |

## note_ordinal_priorities

Input: For the launch there are three priorities. First update Velora. Second post it on Hacker News. Third post the first comment.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | For the launch, there are three priorities:<br>1. Update Velora.<br>2. Post it on Hacker News.<br>3. Post the first comment. | — |
| Qwen 2B4 | For the launch:<br>1. Update Velora.<br>2. Post it on Hacker News.<br>3. Post the first comment. | — |
| Muesli 2B8 | For the launch there are three priorities. First update Velora. Second post it on Hacker News. Third post the first comment. | missing:Hacker News, missing:first comment, missing:update Velora, numbered_items:0!=expected:3 |
| Vedu 0.8B | For the launch there are three priorities:<br>1. Update Velora<br>2. Post it on Hacker News<br>3. Post the first comment. | — |
| Muesli 0.8B8 | For the launch there are three priorities. First update Velora. Second post it on Hacker News. Third post the first comment. | missing:Hacker News, missing:first comment, missing:update Velora, numbered_items:0!=expected:3 |
| Qwen 2B8 | For the launch:<br>1. Update Velora.<br>2. Post it on Hacker News.<br>3. Post the first comment. | — |

## rambling_multi_problem_request

Input: Velora feels very slow compared with Wispr Flow and longer dictations take too much time to return the text and I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | 1. Velora feels very slow compared with Wispr Flow and longer dictations take too much time to return the text.<br>2. I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost. | — |
| Qwen 2B4 | 1. Velora feels very slow compared with Wispr Flow.<br>2. Longer dictations take too much time to return the text.<br>3. I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost. | numbered_items:3!=expected:2 |
| Muesli 2B8 | Velora feels very slow compared with Wispr Flow and longer dictations take too much time to return the text and I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost. | missing:issue reports, missing:longer dictations, numbered_items:0!=expected:2 |
| Vedu 0.8B | Velora feels very slow compared with Wispr Flow and longer dictations take too much time to return the text, and I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost. | missing:issue reports, missing:longer dictations, numbered_items:0!=expected:2 |
| Muesli 0.8B8 | Velora feels very slow compared with Wispr Flow and longer dictations take too much time to return the text and I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost. | missing:issue reports, missing:longer dictations, numbered_items:0!=expected:2 |
| Qwen 2B8 | 1. Velora feels very slow compared with Wispr Flow.<br>2. Longer dictations take too much time to return the text.<br>3. I also do not feel it is smart about issue reports because separate problems stay in one paragraph and the intended structure is lost. | numbered_items:3!=expected:2 |

## single_issue_stays_prose

Input: the only issue I found is that the settings window opens slowly after the first launch but everything else behaves correctly and should stay unchanged

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | The only issue I found is that the settings window opens slowly after the first launch, but everything else behaves correctly and should stay unchanged. | — |
| Qwen 2B4 | 1. The settings window opens slowly after the first launch. | missing:everything else, missing:only issue, numbered_items:1!=expected:0, unexpected_list_items |
| Muesli 2B8 | the only issue I found is that the settings window opens slowly after the first launch but everything else behaves correctly and should stay unchanged. | — |
| Vedu 0.8B | The only issue I found is that the settings window opens slowly after the first launch, but everything else behaves correctly and should stay unchanged. | — |
| Muesli 0.8B8 | the only issue I found is that the settings window opens slowly after the first launch but everything else behaves correctly and should stay unchanged. | — |
| Qwen 2B8 | 1. The settings window opens slowly after the first launch. | missing:everything else, missing:only issue, numbered_items:1!=expected:0, unexpected_list_items |

## temporal_narrative_stays_prose

Input: First I woke up early and made coffee. Second I walked to the station. Third I remembered that I had left my notebook at home, so I went back for it.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | First, I woke up early and made coffee. Second, I walked to the station. Third, I remembered that I had left my notebook at home, so I went back for it. | — |
| Qwen 2B4 | First I woke up early and made coffee.<br>Second I walked to the station.<br>Third I remembered that I had left my notebook at home, so I went back for it. | — |
| Muesli 2B8 | 1. Woke up early and made coffee.<br>2. Walked to the station.<br>3. Remembered leaving the notebook at home, so went back for it. | numbered_items:3!=expected:0, unexpected_list_items |
| Vedu 0.8B | 1. I woke up early and made coffee<br>2. I walked to the station<br>3. I remembered that I had left my notebook at home, so I went back for it. | numbered_items:3!=expected:0, unexpected_list_items |
| Muesli 0.8B8 | 1. I woke up early and made coffee.<br>2. I walked to the station.<br>3. I remembered that I had left my notebook at home, so I went back for it. | numbered_items:3!=expected:0, unexpected_list_items |
| Qwen 2B8 | First, I woke up early and made coffee.<br>Second, I walked to the station.<br>Third, I remembered that I had left my notebook at home, so I went back for it. | — |

## ordinal_nouns_stay_prose

Input: This is my first time visiting the office on the second floor, and the third room on the left is where the design team works.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | This is my first time visiting the office on the second floor, and the third room on the left is where the design team works. | — |
| Qwen 2B4 | This is my first time visiting the office on the second floor, and the third room on the left is where the design team works. | cleanup_not_applied |
| Muesli 2B8 | This is my first time visiting the office on the second floor, and the third room on the left is where the design team works. | — |
| Vedu 0.8B | This is my first time visiting the office on the second floor, and the third room on the left is where the design team works. | — |
| Muesli 0.8B8 | This is my first time visiting the office on the second floor, and the third room on the left is where the design team works. | — |
| Qwen 2B8 | 1. This is my first time visiting the office on the second floor.<br>2. The third room on the left is where the design team works. | numbered_items:2!=expected:0, unexpected_list_items |

## counted_narrative_becomes_list

Input: Three things happened today. First I overslept. Second I missed the standup. Third my badge stopped working, so I had to wait for security.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Three things happened today:<br>1. I overslept.<br>2. I missed the standup.<br>3. My badge stopped working, so I had to wait for security. | — |
| Qwen 2B4 | Three things happened today:<br>1. I overslept.<br>2. I missed the standup.<br>3. My badge stopped working, so I had to wait for security. | — |
| Muesli 2B8 | Three things happened today. First I overslept. Second I missed the standup. Third my badge stopped working, so I had to wait for security. | missing:badge, missing:overslept, missing:standup, numbered_items:0!=expected:3 |
| Vedu 0.8B | Three things happened today:<br>1. I overslept<br>2. I missed the standup<br>3. My badge stopped working, so I had to wait for security. | — |
| Muesli 0.8B8 | Three things happened today. First I overslept. Second I missed the standup. Third my badge stopped working, so I had to wait for security. | missing:badge, missing:overslept, missing:standup, numbered_items:0!=expected:3 |
| Qwen 2B8 | Three things happened today:<br>1. I overslept.<br>2. I missed the standup.<br>3. My badge stopped working, so I had to wait for security. | — |

## ordinary_counting_stays_prose

Input: During practice he counted one two three four five and then jumped into the pool while everyone watched from the side.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | During practice, he counted one, two, three, four, five, and then jumped into the pool while everyone watched from the side. | — |
| Qwen 2B4 | 1. During practice, he counted one, two, three, four, and five, and then jumped into the pool while everyone watched from the side. | numbered_items:1!=expected:0, unexpected_list_items |
| Muesli 2B8 | During practice he counted one two three four five and then jumped into the pool while everyone watched from the side. | — |
| Vedu 0.8B | During practice he counted one, two, three, four, five, and then jumped into the pool while everyone watched from the side. | — |
| Muesli 0.8B8 | During practice he counted one two three four five and then jumped into the pool while everyone watched from the side. | — |
| Qwen 2B8 | 1. During practice he counted one, two, three, four, and five, and then jumped into the pool while everyone watched from the side. | numbered_items:1!=expected:0, unexpected_list_items |

## new_topic_follows_implicit_list

Input: Today's shopping list has three items. First I need to buy books. Second I need to buy apples. Third I need to buy eggs. Anyway, I will head out at noon.

| Model | Output | Failed predicates |
|---|---|---|
| Baseline Qwen 4B8 | Today's shopping list has three items:<br>1. Buy books.<br>2. Buy apples.<br>3. Buy eggs.<br><br>Anyway, I will head out at noon. | — |
| Qwen 2B4 | Today's shopping list has three items:<br>1. Buy books.<br>2. Buy apples.<br>3. Buy eggs.<br>Anyway, I will head out at noon. | — |
| Muesli 2B8 | Today's shopping list has three items. First I need to buy books. Second I need to buy apples. Third I need to buy eggs. I will head out at noon. | missing:buy apples, missing:buy books, missing:buy eggs, numbered_items:0!=expected:3 |
| Vedu 0.8B | Today's shopping list has three items:<br>1. I need to buy books<br>2. I need to buy apples<br>3. I need to buy eggs<br><br>Anyway, I will head out at noon. | — |
| Muesli 0.8B8 | Today's shopping list has three items. First I need to buy books. Second I need to buy apples. Third I need to buy eggs. I will head out at noon. | missing:buy apples, missing:buy books, missing:buy eggs, numbered_items:0!=expected:3 |
| Qwen 2B8 | Today's shopping list has three items:<br>1. Buy books.<br>2. Buy apples.<br>3. Buy eggs.<br>Anyway, I will head out at noon. | — |
