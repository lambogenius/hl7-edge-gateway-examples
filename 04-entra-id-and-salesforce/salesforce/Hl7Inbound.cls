@RestResource(urlMapping='/Hl7Inbound/*')
global with sharing class Hl7Inbound {
    // Receives HL7 messages from HL7 Edge Gateway: keeps each one as a file titled "HL7 <control id>"
    // and answers with an HL7 ACK.
    @HttpPost
    global static void receive() {
        String msg = RestContext.request.requestBody.toString();
        List<String> fields = msg.split('\r')[0].split('\\|');
        String controlId = fields.size() > 9 ? fields[9] : 'unknown';
        insert new ContentVersion(Title = 'HL7 ' + controlId, PathOnClient = controlId + '.hl7', VersionData = Blob.valueOf(msg));
        String ack = 'MSH|^~\\&|SALESFORCE|ORG|EDGE|EDGE|' + Datetime.now().formatGmt('yyyyMMddHHmmss') + '||ACK|A' + controlId + '|P|2.5.1\r'
            + 'MSA|AA|' + controlId + '|stored in Salesforce\r';
        RestContext.response.addHeader('Content-Type', 'text/plain');
        RestContext.response.responseBody = Blob.valueOf(ack);
    }
}
