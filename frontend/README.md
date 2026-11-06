# NEXA BILLFLOW — Flutter app (Step 4)

Flutter client for the NEXA BILLFLOW FastAPI backend (Step 3), Supabase Auth, and the Whitechain Sepolia contracts (Step 2).

> **Honest status:** this code was written in an environment with **no Flutter SDK and no pub.dev access**. It has **not been
> compiled, analysed, run or tested**. The first thing to do is `flutter pub get && flutter analyze && flutter test` and fix whatever
> the compiler finds. See `docs/FLUTTER_APP.md` for the full status and blockers.

## First run

```bash
cd frontend
flutter create . --platforms=web,android,ios --project-name billflow   # generates web/, android/, ios/ (keeps lib/ and pubspec.yaml)
flutter pub get
cp .env.example .env                # fill in PUBLIC values only (bundled into the app as an asset)
flutter analyze
flutter test
flutter run -d chrome               # config is read from .env at startup
```

`flutter create .` may rewrite `pubspec.yaml` dependencies' comments only; if it overwrites `pubspec.yaml`, restore ours from git.
Package versions in `pubspec.yaml` were chosen from memory and are unverified: if `pub get` complains, relax them.

## Configuration (public values only)

| Key | Meaning |
|---|---|
| `API_BASE_URL` | FastAPI base, e.g. `https://api.example.com/api/v1` |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Supabase **anon** key (never the service-role key) |
| `CHAIN_ID`, `RPC_URL`, `EXPLORER_URL` | Whitechain Sepolia: 1874 / https://rpc.testnet.whitechain.io / https://explorer.testnet.whitechain.io |
| `CHECKOUT_BASE_URL` | Optional; payment links are built by the backend |

Contract and USDT addresses are **not** configured here: they come from the backend (`/blockchain/config`, `/public/invoices/{token}`),
which reads the verified Step 2 deployment. No Anthropic key, service-role key, deployer key or backend secret ever belongs in this app.

## Supabase / hosting checklist
* Supabase Auth: enable email+password, set the **Site URL / redirect URLs** to your web origin (email verification and password-recovery links return there).
* Web hosting must rewrite unknown paths to `index.html` (the app uses path URLs such as `/pay/<token>`).
* Backend CORS must allow the web origin.
* Wallet: Flutter **Web** with a browser wallet (MetaMask etc.) is supported. **Mobile WalletConnect is not implemented**; on Android/iOS the wallet panel explains this.

## Structure
```
lib/
  main.dart                      Supabase init, ProviderScope
  app/        app.dart router.dart shell.dart providers.dart theme/
  core/       config/ errors/ network/(Dio ApiClient) services/wallet/ utils/(abi, format, validators) widgets/
  data/       billflow_api.dart  (every Step 3 endpoint used by the app)
  shared/     models/ widgets/(PagedList)
  features/   authentication onboarding business customers invoices dashboard financing marketplace investments
              checkout wallet notifications transactions profile settings admin
test/         abi, format/validators, models, router redirect, invoice pdf (written, NOT executed)
```
