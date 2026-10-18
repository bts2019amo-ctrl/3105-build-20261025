#import "exploit/bad_query.h"
#import "exploit/mcm_bridge.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/sandbox_escape.h"
#import "kexploit/kutils.h"
#import "helpers/AppIconHelper.h"
#import "helpers/DisplayIdentity.h"

// AntiDetection runtime protection
int AD_isTampered(void);
void AD_applyEarlyProtections(void);
void AD_killProcess(void);
