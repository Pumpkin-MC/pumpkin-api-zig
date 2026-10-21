# Realm

A small economy plugin that uses every helper of the package. `zig build` builds it into `zig-out/example-realm.wasm`.

Players earn coins by mining ores, from a daily reward with a streak and on payday. They spend them in a shop menu, pay each other and write cheques. Operators can start coin rushes, during which ores pay more.

## Commands

| Command | Does |
| --- | --- |
| `/realm` | Shows your coins, with buttons for the commands below |
| `/balance [player]`, `/bal` | Shows your coins or another player's |
| `/daily` | Claims the daily reward. Claiming on consecutive days raises it |
| `/pay <player> [amount]` | Gives coins. Without an amount it asks in chat, then asks you to confirm |
| `/shop` | Opens the shop. Click buys once, shift click buys 8 times |
| `/buy <offer> [times]` | Buys from the shop without opening it, with the offers suggested |
| `/cheque <amount>` | Turns coins into a cheque. Whoever right clicks with it gets the coins |
| `/realmadmin reload` | Reloads the config |
| `/realmadmin rush [seconds]` | Starts a coin rush with a boss bar countdown |
| `/realmadmin grant <players> <amount>` | Gives coins to players |

`/realmadmin` needs operator level 2. Everyone can run the other commands.

## Outside the game

- A sidebar shows the coins of everyone online.
- `nc 127.0.0.1 25581` opens the ledger, which answers `online`, `rush` and `quit`.
- Set `webhook` to a Discord webhook URL to announce coin rushes there. HTTPS also needs `ca-certificates.crt` in the plugin's data folder.
- Other plugins can send the IPC message `balance <uuid>` and get the player's coins back.

## Files

Everything is in `plugins/data/example-realm/`. `config.toml` holds the currency name, rewards, ores, shop offers, rush length, ledger port and webhook. `players/` has one TOML file per player. The plugin asks for the `fs.read.data`, `fs.write.data`, `network.dns`, `network.tcp.connect` and `network.tcp.bind` permissions.

| File | Helpers it shows |
| --- | --- |
| [`main.zig`](main.zig) | `register`, events, `cmd` trees with typed arguments, `tasks` |
| [`settings.zig`](settings.zig) | `config` with tables and arrays of tables |
| [`coins.zig`](coins.zig) | `store` with the TOML codec, `msg`, a scoreboard sidebar |
| [`shop.zig`](shop.zig) | `menu`, `item.room` and `item.give`, `cmd` suggestions |
| [`pay.zig`](pay.zig) | `prompt.ask` and `prompt.choose` |
| [`cheque.zig`](cheque.zig) | `item.build` with stored data, `item.held`, particles |
| [`rush.zig`](rush.zig) | `tasks` with state, a boss bar, `http.sendJson` |
| [`ledger.zig`](ledger.zig) | `net.listen` and IPC |

The plugin plays no sounds, since `playSound` traps on the v0.1 host: the host can't turn the sound's name into the one it looks up.
