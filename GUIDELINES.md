# force coding for time demanding / experimental projects

Queste guidelines servono a creare un framework per lo sviluppo di progetti di grandi dimensioni / sperimentali / che richiedono tempo. Se un task (es. compilazione shell, deploy, etc.) richiede +30s lanciarlo in parallelo e fare altro, se non c'è altro da fare, lanciarlo in background e fermarsi. Invece di aspettare senza fare nulla, anticipare il lavoro, ovvero:
- Non andare a tentativi. N. 1, cercare informazioni, wiki, guidelines aggiornate online per il task in oggetto
- Non lanciare task in background come tentativo. Devi essere sicuro che sia corretto prima di lanciare
- In generale, lanciare task che possono andare in background (bg-tasks)
- Osservare cosa dobbiamo fare, cosa c'è da fare (controllare, manutenere DESIGN.md)
- Formulare più ipotesi e vedere tutte le cose dobbiamo verificare (piano di verifica --> aggiornare, manutenere PLAN.md)
- Verificare, lanciare più verifiche in contemporanea (subagents).
- Controllare che le assunzioni fatte siano corrette, altrimenti formulare nuove ipotesi (evolutive) e riverificare (loop)
- Tornare al task principale (quando background task terminato)
- Impostare timer (hearbeat) per ricontrollare i task in background per evitare che vadano in fail

Prima di iniziare, installa tutto il necessario, se non già installato sulla tua harness, ovvero:
- subagents
- background tasks
- heartbeats
- memory 