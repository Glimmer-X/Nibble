#!/usr/bin/env python3
"""Writes a few made-up conversations into a Nibble data folder, for screenshots.

    scripts/demo-data.py DATA_DIR [en]

Replaces DATA_DIR/conversations (in English with `en`); leaves settings.json alone. The newest
conversation is from a minute ago, so the panel opens on it. Used by scripts/shot.sh,
scripts/screens.sh and scripts/demo.sh.
"""
import json, os, shutil, sys, uuid
from datetime import datetime, timedelta, timezone

CHATS = [
    (0.0007, "general", [
        ("溏心蛋要煮几分钟？",
         "冰箱里拿出来的大号鸡蛋，水开后煮 **6 分半**。\n\n1. 把水烧到大滚。\n2. 用勺子把蛋轻轻放进去。\n3. 6 分半后捞出，泡进冰水 2 分钟。\n\n| 时间 | 蛋黄 |\n|---|---|\n| 6 分钟 | 流心 |\n| 6 分半 | 溏心 |\n| 8 分钟 | 刚凝固 |\n\n小一点的蛋少煮 30 秒。", 4.2, 58),
    ]),
    (0.02, "general", [
        ("把这段话改得更口语一点：本产品旨在为用户提供便捷的信息获取途径。",
         "可以这样说：\n\n「用它查东西更方便。」\n\n如果想保留一点介绍的语气，也可以写成「想查什么，用它就能很快找到」。", 3.1, 62),
        ("再短一点", "「查东西更快。」", 0.8, 70),
    ]),
    (0.3, "general", [
        ("macOS 上怎么查看某个端口被哪个进程占用？",
         "用 `lsof`：\n\n```\nlsof -nP -iTCP:8642 -sTCP:LISTEN\n```\n\n输出里的 `COMMAND` 和 `PID` 就是占用端口的进程。要结束它，可以 `kill <PID>`。", 5.4, 48),
    ]),
    (1.1, "writing", [
        ("帮我列一个周末去京都两天的行程，坐电车出行。",
         "**第一天**\n\n1. 早上去伏见稻荷，赶在人多之前走千本鸟居。\n2. 中午到祇园吃饭，下午沿花见小路走到清水寺。\n3. 傍晚在鸭川边散步。\n\n**第二天**\n\n1. 坐电车去岚山，看竹林和渡月桥。\n2. 回城后去金阁寺。\n3. 晚上在锦市场买点小吃。", 8.2, 55),
    ]),
    (2.4, "general", [
        ("一个 4K 显示器和一个 1080p 显示器，Mac 上缩放怎么设比较清楚？",
         "4K 屏选「更多空间」左边一档，相当于 2560 × 1440 的 HiDPI，字最清楚。1080p 屏没有 HiDPI，保持默认 1920 × 1080 即可。两块屏的缩放互不影响。", 2.0, 66),
    ]),
    (3.6, "coding", [
        ("Swift 里怎么让一个 struct 在 JSON 缺字段时用默认值？",
         "自己写 `init(from:)`，对每个字段用 `decodeIfPresent`，缺了就用默认值：\n\n```swift\ninit(from decoder: Decoder) throws {\n    let c = try decoder.container(keyedBy: CodingKeys.self)\n    name = try c.decodeIfPresent(String.self, forKey: .name) ?? \"\"\n}\n```", 6.7, 51),
    ]),
]

CHATS_EN = [
    (0.0007, "general", [
        ("How long should I boil an egg for a jammy yolk?",
         "For a jammy yolk, boil a large egg straight from the fridge for **6½ minutes**.\n\n1. Bring a pan of water to a rolling boil.\n2. Lower the eggs in gently with a spoon.\n3. After 6½ minutes, move them to iced water for 2 minutes.\n\n| Time | Yolk |\n|---|---|\n| 6 min | runny |\n| 6½ min | jammy |\n| 8 min | just set |\n\nSmaller eggs need about 30 seconds less.", 4.2, 58),
    ]),
    (0.05, "general", [
        ("Make this sound friendlier: Your request has been received and will be processed.",
         "Thanks, we've got your request and we're on it.", 2.4, 64),
    ]),
    (0.4, "general", [
        ("How do I see which process is using port 8642 on a Mac?",
         "Use `lsof`:\n\n```\nlsof -nP -iTCP:8642 -sTCP:LISTEN\n```\n\nThe `COMMAND` and `PID` columns tell you which process it is.", 5.1, 50),
    ]),
    (1.2, "writing", [
        ("Plan a two-day weekend in Kyoto, getting around by train.",
         "**Day one**\n\n1. Fushimi Inari early, before the crowds reach the gates.\n2. Lunch in Gion, then walk up to Kiyomizu-dera.\n3. An evening walk along the Kamo River.\n\n**Day two**\n\n1. Train to Arashiyama for the bamboo grove.\n2. Back in town, Kinkaku-ji.\n3. Snacks at Nishiki Market.", 7.8, 56),
    ]),
    (2.5, "coding", [
        ("In Swift, how do I give a Codable struct default values for missing JSON keys?",
         "Write `init(from:)` and use `decodeIfPresent` with a default for each key.", 6.2, 52),
    ]),
]


def iso(d):
    return d.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond // 1000:03d}Z"


def main():
    root = os.path.join(sys.argv[1], "conversations")
    shutil.rmtree(root, ignore_errors=True)
    now = datetime.now(timezone.utc)
    chats = CHATS_EN if len(sys.argv) > 2 and sys.argv[2] == "en" else CHATS
    for days, persona, turns in chats:
        start = now - timedelta(days=days)
        cid = str(uuid.uuid4()).upper()
        messages, t = [], start
        for question, answer, work, speed in turns:
            messages.append({"id": str(uuid.uuid4()).upper(), "role": "user", "text": question, "reasoning": "",
                             "attachments": [], "createdAt": iso(t), "status": {"complete": {}}})
            t += timedelta(seconds=work + 4)
            messages.append({"id": str(uuid.uuid4()).upper(), "role": "assistant", "text": answer, "reasoning": "",
                             "attachments": [], "createdAt": iso(t), "status": {"complete": {}},
                             "stats": {"waitSeconds": 0.6, "workSeconds": work, "writeSeconds": 3.0,
                                       "tokensPerSecond": speed, "model": "demo",
                                       "usage": {"inputTokens": 900, "outputTokens": 240}}})
            t += timedelta(seconds=30)
        conversation = {"id": cid, "createdAt": iso(start), "updatedAt": iso(t), "messages": messages, "persona": persona}
        folder = os.path.join(root, cid)
        os.makedirs(folder)
        path = os.path.join(folder, "conversation.json")
        with open(path, "w") as f:
            json.dump(conversation, f, ensure_ascii=False, indent=2)
        # Nibble orders conversations by when their file was last written.
        os.utime(path, (t.timestamp(), t.timestamp()))


if __name__ == "__main__":
    main()
