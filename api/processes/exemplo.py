from pygeoapi.process.base import BaseProcessor


PROCESS_METADATA = {
    "version": "1.0.0",
    "id": "exemplo",
    "title": "Processo de exemplo",
    "description": "Processo de teste da OGC API - Processes",
    "jobControlOptions": ["sync-execute"],
    "outputTransmission": ["value"],
    "inputs": {
        "mensagem": {
            "title": "Mensagem",
            "description": "Mensagem de entrada",
            "schema": {
                "type": "string"
            }
        }
    },
    "outputs": {
        "resultado": {
            "title": "Resultado",
            "schema": {
                "type": "string"
            }
        }
    }
}


class ExemploProcessor(BaseProcessor):

    def __init__(self, provider_def):
        super().__init__(provider_def)

    def execute(self, data):
        mensagem = data.get("mensagem", "Olá!")

        return {
            "resultado": f"Processamento executado: {mensagem}"
        }

    def __repr__(self):
        return "<ExemploProcessor>"