package vf;

import chemaxon.marvin.calculations.*;
import chemaxon.struc.*;
import chemaxon.formats.MolImporter;
import chemaxon.marvin.*;
import chemaxon.marvin.plugin.*;
import com.chemaxon.calculations.solubility.SolubilityCalculator;
import com.chemaxon.calculations.stereoisomers.*;
import com.chemaxon.calculations.stereoisomers.StereoisomerSettings.*;
import java.util.EnumSet;

public class CxCalcAttr {

	TopologyAnalyserPlugin pTAP;
	int pTAPInit = 0;

	HBDAPlugin pHBDA;
	int pHBDAInit = 0;


	private void initPTAP(Molecule mol) throws PluginException {
		if (pTAPInit == 0) {
			pTAP = new TopologyAnalyserPlugin();
			pTAP.setMolecule(mol);
			pTAP.run();
			pTAPInit = 1;
		}
	}

	private void initPHBDA(Molecule mol) throws PluginException {
		if (pHBDAInit == 0) {
			pHBDA = new HBDAPlugin();
			pHBDA.setMolecule(mol);
			pHBDA.run();
			pHBDAInit = 1;
		}
	}


	public static void main(String[] args) {
		CxCalcAttr attr = new CxCalcAttr();

		try {

			MolImporter mi = new MolImporter(args[0]);
			Molecule mol = mi.read();
			mi.close();
			
			for (int i = 1; i < args.length; i++) {
				String element = args[i];

				switch (element.toLowerCase()) {
					case "doublebondstereoisomercount":
						StereoisomerSettings settings = StereoisomerSettings.create()
							.setStereoisomerType(EnumSet.of(StereoisomerType.CISTRANS));
						StereoisomerEnumeration enumeration =
							new StereoisomerEnumeration(mol, settings);
						System.out.println("doublebondstereoisomercount," + enumeration.getStereoisomerCount());
						break;

					case "aromaticproportion":
						attr.initPTAP(mol);

						int heavyAtomCount = attr.pTAP.getAliphaticAtomCount() + attr.pTAP.getAromaticAtomCount();
						float aromaticProportion =  (float) attr.pTAP.getAromaticAtomCount() / (float) heavyAtomCount;
						System.out.println("aromaticproportion," + aromaticProportion);
						break;

					case "logp":

						logPPlugin pLogP = new logPPlugin();
						pLogP.setMolecule(mol);
						pLogP.run();

						System.out.println("logp," + pLogP.getlogPTrue());

						break;
					case "logd":

						logDPlugin pLogD = new logDPlugin();
						pLogD.setMolecule(mol);
						plugin.setpH(7.4)
						pLogD.run();

						System.out.println("logd," + pLogD.getlogD());
						break;

					case "logs":

						SolubilityCalculator calculator = new SolubilityCalculator();
						System.out.println("logs," + calculator.calculatePhDependentSolubility(mol,7.4).getSolubility());
						break;

					case "mass":

						ElementalAnalyserPlugin pEAP = new ElementalAnalyserPlugin();
						pEAP.setMolecule(mol);
						pEAP.run();

						System.out.println("mass," + pEAP.getMass());
						break;

					case "rotatablebondcount":
						attr.initPTAP(mol);
						System.out.println("rotatablebondcount," + attr.pTAP.getRotatableBondCount());
						break;

					case "bondcount":
						attr.initPTAP(mol);
						System.out.println("bondcount," + attr.pTAP.getBondCount());
						break;

					case "ringcount":
						attr.initPTAP(mol);
						System.out.println("ringcount," + attr.pTAP.getRingCount());
						break;

					case "aromaticringcount":
						attr.initPTAP(mol);
						System.out.println("aromaticringcount," + attr.pTAP.getAromaticRingCount());
						break;

					case "fsp3":
						attr.initPTAP(mol);
						System.out.println("fsp3," + attr.pTAP.getFsp3());
						break;

					case "chiralcentercount":
						attr.initPTAP(mol);
						System.out.println("chiralcentercount," + attr.pTAP.getChiralCenterCount());
						break;

					case "refractivity":
						RefractivityPlugin pRefractivity = new RefractivityPlugin();
						pRefractivity.setMolecule(mol);
						pRefractivity.run();

						System.out.println("refractivity," + pRefractivity.getRefractivity());
						break;

					case "polarsurfacearea":
						TPSAPlugin pTPSA = new TPSAPlugin();
						pTPSA.setMolecule(mol);
						pTPSA.run();

						System.out.println("polarsurfacearea," + pTPSA.getSurfaceArea());
						break;

					case "donorcount":
						attr.initPHBDA(mol);
						System.out.println("donorcount," + attr.pHBDA.getDonorSiteCount());
						break;

					case "acceptorcount":
						attr.initPHBDA(mol);
						System.out.println("acceptorcount," + attr.pHBDA.getAcceptorSiteCount());
						break;

					case "atomcount":
						attr.initPHBDA(mol);
						System.out.println("atomcount," + attr.pHBDA.getAtomCount());
						break;

					default:
						System.out.println(element.toLowerCase() + ",INVALID");
						break;
				}
			}

		} catch(Exception e) {
        	System.out.println("ERROR:" + e); 
		}




    }
}
