// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The part of Final Cut Pro's FCPXML 1.11 DTD (`FCPXMLv1_11.dtd`) for the elements the export writes, written here by
/// hand (the app ships no DTD and reads none): every element with the content model and the attributes 1.11 gives it, its
/// required attributes required and its enumerations closed, the children it does not write left out of the models. A
/// document the export writes that `XMLDocument.validate()` passes against it uses each element as Final Cut reads it.
enum FCPXMLDTD {
    static let source = """
        <!ENTITY % time "CDATA">

        <!ELEMENT fcpxml (resources?, library)>
        <!ATTLIST fcpxml version CDATA #FIXED "1.11">

        <!ELEMENT resources (format | asset)*>

        <!ELEMENT format EMPTY>
        <!ATTLIST format id ID #REQUIRED>
        <!ATTLIST format name CDATA #IMPLIED>
        <!ATTLIST format frameDuration %time; #IMPLIED>
        <!ATTLIST format fieldOrder CDATA #IMPLIED>
        <!ATTLIST format width CDATA #IMPLIED>
        <!ATTLIST format height CDATA #IMPLIED>
        <!ATTLIST format paspH CDATA #IMPLIED>
        <!ATTLIST format paspV CDATA #IMPLIED>
        <!ATTLIST format colorSpace CDATA #IMPLIED>

        <!ELEMENT asset (media-rep+)>
        <!ATTLIST asset id ID #REQUIRED>
        <!ATTLIST asset name CDATA #IMPLIED>
        <!ATTLIST asset start %time; #IMPLIED>
        <!ATTLIST asset duration %time; #IMPLIED>
        <!ATTLIST asset uid CDATA #IMPLIED>
        <!ATTLIST asset format IDREF #IMPLIED>
        <!ATTLIST asset hasVideo (0 | 1) "0">
        <!ATTLIST asset hasAudio (0 | 1) "0">
        <!ATTLIST asset audioSources CDATA #IMPLIED>
        <!ATTLIST asset audioChannels CDATA #IMPLIED>
        <!ATTLIST asset audioRate CDATA #IMPLIED>
        <!ATTLIST asset videoSources CDATA #IMPLIED>

        <!ELEMENT media-rep EMPTY>
        <!ATTLIST media-rep kind (original-media | proxy-media) "original-media">
        <!ATTLIST media-rep sig CDATA #IMPLIED>
        <!ATTLIST media-rep src CDATA #REQUIRED>
        <!ATTLIST media-rep suggestedFilename CDATA #IMPLIED>

        <!ELEMENT library (event*)>
        <!ATTLIST library location CDATA #IMPLIED>
        <!ATTLIST library colorProcessing (standard | wide | wide-hdr) "standard">

        <!ELEMENT event (project)*>
        <!ATTLIST event name CDATA #IMPLIED>
        <!ATTLIST event uid CDATA #IMPLIED>

        <!ELEMENT project (sequence)>
        <!ATTLIST project name CDATA #IMPLIED>
        <!ATTLIST project uid CDATA #IMPLIED>
        <!ATTLIST project id ID #IMPLIED>
        <!ATTLIST project modDate CDATA #IMPLIED>

        <!ELEMENT sequence (spine)>
        <!ATTLIST sequence format IDREF #REQUIRED>
        <!ATTLIST sequence duration %time; #IMPLIED>
        <!ATTLIST sequence tcStart %time; #IMPLIED>
        <!ATTLIST sequence tcFormat (DF | NDF) #IMPLIED>
        <!ATTLIST sequence audioLayout (mono | stereo | surround) #IMPLIED>
        <!ATTLIST sequence audioRate (32k | 44.1k | 48k | 88.2k | 96k | 176.4k | 192k) #IMPLIED>
        <!ATTLIST sequence renderFormat CDATA #IMPLIED>
        <!ATTLIST sequence keywords CDATA #IMPLIED>

        <!ELEMENT spine (asset-clip)*>
        <!ATTLIST spine name CDATA #IMPLIED>
        <!ATTLIST spine offset %time; #IMPLIED>
        <!ATTLIST spine format IDREF #IMPLIED>

        <!ELEMENT asset-clip (marker | chapter-marker)*>
        <!ATTLIST asset-clip ref IDREF #REQUIRED>
        <!ATTLIST asset-clip name CDATA #IMPLIED>
        <!ATTLIST asset-clip offset %time; #IMPLIED>
        <!ATTLIST asset-clip start %time; #IMPLIED>
        <!ATTLIST asset-clip duration %time; #REQUIRED>
        <!ATTLIST asset-clip enabled (0 | 1) "1">
        <!ATTLIST asset-clip format IDREF #IMPLIED>
        <!ATTLIST asset-clip tcStart %time; #IMPLIED>
        <!ATTLIST asset-clip tcFormat (DF | NDF) #IMPLIED>
        <!ATTLIST asset-clip srcEnable (all | audio | video) "all">

        <!ELEMENT marker EMPTY>
        <!ATTLIST marker start %time; #REQUIRED>
        <!ATTLIST marker duration %time; #IMPLIED>
        <!ATTLIST marker value CDATA #REQUIRED>
        <!ATTLIST marker completed CDATA #IMPLIED>
        <!ATTLIST marker note CDATA #IMPLIED>

        <!ELEMENT chapter-marker EMPTY>
        <!ATTLIST chapter-marker start %time; #REQUIRED>
        <!ATTLIST chapter-marker duration %time; #IMPLIED>
        <!ATTLIST chapter-marker value CDATA #REQUIRED>
        <!ATTLIST chapter-marker note CDATA #IMPLIED>
        <!ATTLIST chapter-marker posterOffset %time; #IMPLIED>
        """
}
