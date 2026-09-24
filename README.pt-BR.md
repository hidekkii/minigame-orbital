# Orbit Hop

[English](README.md) | **Português (BR)**

Um joguinho arcade de um botão só, em um único arquivo HTML. Seu cometa gira em volta de uma estrela — pule entre a órbita interna e a externa para pegar poeira estelar e desviar dos meteoros.

**Jogue:** https://d20580lqom8vrn.cloudfront.net

## Controles

Toque, clique ou aperte <kbd>Espaço</kbd> para pular entre as órbitas.

## Rodar localmente

Abra `game/index.html` no navegador. Não precisa de build nem de dependências.

## Deploy na AWS

Hospedado em um bucket S3 privado atrás do CloudFront (Origin Access Control, somente HTTPS).

```powershell
aws login --profile <seu-perfil>
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -AwsProfile <seu-perfil> -Region <sua-regiao>
```

O script pode ser rodado várias vezes com segurança: na primeira execução ele cria o bucket, o OAC e a distribuição; nas seguintes, só envia o `index.html` e invalida o cache do CloudFront.
