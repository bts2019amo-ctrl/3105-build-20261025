# Plano de proteção da IPA — 30 camadas

## Limite importante

Nenhuma IPA consegue garantir que **ninguém jamais** a modifique em um dispositivo com jailbreak, debugger ou controle do sistema. A proteção correta é em camadas: o cliente detecta adulteração, mas o servidor decide se a chave, o dispositivo e cada patch podem ser usados.

Também há um conflito entre dois objetivos:

- **IPA oficial atualizada:** os patches devem reaparecer depois da atualização/reinstalação oficial.
- **IPA clonada/modificada:** uma cópia não autorizada não deve conseguir baixar nem descriptografar os patches.

A solução é não confiar na cópia local: após autenticação, a IPA oficial revalida o dispositivo e baixa novamente os patches por URLs assinadas e temporárias.

## 30 proteções recomendadas

### Autorização e servidor

1. **Autorização exclusivamente no servidor:** a IPA nunca decide sozinha se a chave está válida.
2. **Tokens de curta duração:** trocar a chave bruta por access tokens com expiração curta e refresh controlado.
3. **Vinculação chave–usuário–dispositivo:** cada licença deve possuir limite de dispositivos e estado revogável.
4. **Desafio nonce por sessão:** o servidor envia um nonce único; a resposta não pode ser reutilizada.
5. **App Attest:** exigir uma attestation válida da instalação antes de liberar o feed e os arquivos.
6. **DeviceCheck como sinal complementar:** registrar estado de abuso/revogação por dispositivo.
7. **Revogação imediata:** revogar chave, instalação, sessão e URLs já emitidas sem esperar atualização da IPA.
8. **Rate limiting:** limitar login, refresh, feed, download e falhas de senha por chave, IP e dispositivo.
9. **Logs de auditoria:** registrar login, attestation, downloads, versão, dispositivo e motivo de recusa.
10. **Detecção de anomalias:** bloquear uso simultâneo impossível, mudanças bruscas de dispositivo e volume anormal.

### Proteção dos patches remotos

11. **Feed assinado pelo servidor:** assinar o manifesto com uma chave privada que nunca entra na IPA.
12. **Verificação de assinatura no cliente:** aceitar somente manifestos assinados pela chave pública embarcada.
13. **Pacotes assinados individualmente:** cada patch deve ter assinatura própria, não apenas SHA-256.
14. **URLs de download temporárias:** o servidor deve emitir URL assinada com expiração curta e escopo de arquivo.
15. **Não expor URLs públicas permanentes:** remover `fileUrl` reutilizável do feed público.
16. **Checksum + tamanho + tipo obrigatório:** validar assinatura, tamanho máximo, MIME e digest antes de salvar.
17. **Proteção contra replay:** incluir versão, nonce, timestamp e identificador de instalação na autorização do download.
18. **Criptografia por patch/dispositivo:** entregar o conteúdo cifrado para a instalação autorizada, não uma chave pública dentro do pacote.
19. **Rotação de chaves de assinatura:** suportar duas chaves durante a rotação e revogar a antiga no servidor.
20. **Formato sem código executável:** aceitar apenas regras/dados declarativos; rejeitar scripts, dylibs e Mach-O em pacotes.

### Identidade e armazenamento no iOS

21. **Keychain ThisDeviceOnly:** manter tokens e chaves de conteúdo fora de `UserDefaults` e fora de backups.
22. **Access group restrito:** usar access group próprio, sem grupo genérico ou compartilhado desnecessariamente.
23. **Chave de instalação separada:** guardar identidade e segredo de instalação em itens Keychain distintos.
24. **Reautenticação após troca de bundle:** se o bundle, assinatura ou attestation mudar, apagar sessão e exigir nova autorização.
25. **Migração somente para update oficial:** permitir reidratação de patches apenas após attestation e assinatura válidas.
26. **Não confiar em caminho local:** o namespace local pode ser alterado; a fonte de verdade deve ser o servidor.
27. **Limpeza segura em logout/revogação:** apagar tokens, chaves de conteúdo, pacotes temporários e workspaces autorizados.
28. **Proteção de arquivos temporários:** usar diretórios privados, permissões padrão do app e apagar temporários após importação.

### Resistência a adulteração

29. **Verificações de integridade em pontos críticos:** validar assinatura do bundle, imagem carregada, jailbreak/debugger e ambiente antes de login, feed e aplicação de patch. Essas verificações são sinais, não a autorização final.
30. **Redução do valor de engenharia reversa:** strip de símbolos, remover logs sensíveis, não embutir segredos, ofuscar apenas identificadores não críticos e forçar atualização mínima quando uma versão for revogada.

## Situação observada no código atual

Há defesas úteis já presentes:

- fingerprint do bundle e do executável;
- verificação periódica de integridade;
- reset de patches quando a instalação muda;
- Keychain com `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`;
- checksum SHA-256 dos patches baixados;
- autenticação periódica da chave;
- heartbeat do dispositivo;
- armazenamento local separado por namespace.

Há pontos que precisam de evolução para proteção real:

- `syncToken` está embutido no cliente e deve deixar de ser segredo;
- o feed entrega `fileUrl`, que deve virar URL assinada e temporária;
- checksum sozinho não prova autoria; é necessário manifesto e pacote assinados;
- a autorização ainda não exige App Attest/DeviceCheck;
- um novo bundle oficial não deve depender da cópia local: deve rebaixar os patches após reautorização;
- uma IPA modificada não pode ser bloqueada somente por checagens locais; o servidor precisa negar a attestation e os downloads.

## Ordem segura de implementação

1. Backend: manifesto assinado, URLs temporárias, autorização por instalação e revogação.
2. iOS: App Attest/DeviceCheck e protocolo nonce.
3. iOS: verificação de assinatura de feed e pacotes.
4. iOS/backend: reidratação dos patches após update oficial.
5. Hardening local, limpeza de segredos, logs e rate limiting.
6. Testes: IPA oficial, update, reinstalação, bundle alterado, debugger, offline, revogação e replay.

**Conclusão:** a proteção dos patches não deve depender de esconder o arquivo dentro da IPA. O patch remoto deve ser inútil para uma IPA clonada porque o servidor não entrega uma autorização válida nem a chave de conteúdo.
