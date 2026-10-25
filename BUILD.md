# Build do 3105

Este repositório é uma cópia de trabalho independente do projeto original [YangJiiii/3105](https://github.com/YangJiiii/3105). O código-fonte não foi alterado para a compilação.

## Compilação

O projeto é um app iOS nativo em Swift/Objective-C e requer macOS, Xcode e o iOS SDK. O workflow [`Build iOS app`](.github/workflows/build-ios.yml) compila o scheme `3105` em configuração `Release` para `iphoneos`, usando `xcodebuild` em um runner macOS do GitHub Actions. Ele roda ao enviar alterações para `main` e também pode ser iniciado manualmente pela aba **Actions**.

O build usa `CODE_SIGNING_ALLOWED=NO` e `CODE_SIGNING_REQUIRED=NO`. O workflow empacota o app em `3105-RemotePatchCentral.ipa`, mas o arquivo é **não assinado** e não está pronto para instalação em dispositivo. O artefato do GitHub Actions, `3105-remote-patch-central-ipa`, inclui a IPA e o log completo do Xcode, com retenção de 14 dias.

## Verificação local

A compilação não pode ser executada diretamente em Linux porque `xcodebuild` e os SDKs Apple não estão disponíveis. O workflow macOS do GitHub Actions é a forma reproduzível de compilar este projeto.

## Instalação em dispositivo

A instalação em dispositivo exige assinatura, provisionamento e os certificados apropriados. Esses materiais não fazem parte deste repositório e não foram incluídos nesta cópia.
