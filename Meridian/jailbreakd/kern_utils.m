#import <Foundation/Foundation.h>

#include <sched.h>
#include <sys/stat.h>

#include "common.h"
#include "kern_utils.h"
#include "kexecute.h"
#include "kmem.h"
#include "offsetof.h"
#include "osobject.h"
#include "sandbox.h"

mach_port_t tfp0;
uint64_t kernel_base;
uint64_t kernel_slide;

uint64_t kernprocaddr;
uint64_t offset_zonemap;

uint64_t offset_add_ret_gadget;
uint64_t offset_osboolean_true;
uint64_t offset_osboolean_false;
uint64_t offset_osunserializexml;
uint64_t offset_smalloc;

// Please call `proc_release` after you are finished with your proc!
uint64_t proc_find(int pd) {
    uint64_t proc = kernprocaddr;
    
    while (proc) {
        uint32_t found_pid = rk32(proc + 0x10);
        
        if (found_pid == pd) {
            return proc;
        }
        
        proc = rk64(proc + 0x8);
    }
    
    return 0;
}

CACHED_FIND(uint64_t, our_task_addr) {
    // proc_find won't work as it requires kexecute, which
    // is not yet set up when this is called. we will just
    // manually walk the proc list instead
    uint64_t proc = rk64(kernprocaddr + 0x8);
    
    while (proc) {
        uint32_t proc_pid = rk32(proc + 0x10);
        
        if (proc_pid == getpid()) {
            break;
        }
        
        proc = rk64(proc + 0x8);
    }
    
    if (proc == 0) {
        fprintf(stdout, "failed to find our_task_addr!\n");
        exit(EXIT_FAILURE);
    }

    return rk64(proc + offsetof_task);
}

uint64_t find_port(mach_port_name_t port) {
    uint64_t task_addr = our_task_addr();
  
    uint64_t itk_space = rk64(task_addr + offsetof_itk_space);
  
    uint64_t is_table = rk64(itk_space + offsetof_ipc_space_is_table);
  
    uint32_t port_index = port >> 8;
    const int sizeof_ipc_entry_t = 0x18;
  
    return rk64(is_table + (port_index * sizeof_ipc_entry_t));
}

void set_csflags(uint64_t proc) {
    uint32_t pid = rk32(proc + 0x10);
    
    uint32_t csflags = rk32(proc + offsetof_p_csflags);

    csflags = (csflags | CS_PLATFORM_BINARY | CS_INSTALLER | CS_GET_TASK_ALLOW | CS_DEBUGGED) & ~(CS_RESTRICT | CS_HARD | CS_KILL);
    
    wk32(proc + offsetof_p_csflags, csflags);
}

void set_csblob(uint64_t proc) {
    uint64_t textvp = rk64(proc + offsetof_p_textvp); // vnode of executable
    if (textvp == 0) return;
    
    uint64_t textoff = rk64(proc + offsetof_p_textoff);

    uint16_t vnode_type = rk16(textvp + offsetof_v_type);
    if (vnode_type != 1) return; // 1 = VREG
    
    uint64_t ubcinfo = rk64(textvp + offsetof_v_ubcinfo);

    // Loop through all csblob entries (linked list) and update
    // all (they must match by design)
    uint64_t csblob = rk64(ubcinfo + offsetof_ubcinfo_csblobs);
    while (csblob != 0) {
        wk32(csblob + offsetof_csb_platform_binary, 1);
        
        csblob = rk64(csblob);
    }
}

const char* abs_path_exceptions[] = {
    "/Library",
    "/private/var/mobile/Library",
    "/private/var/mnt",
    NULL
};

uint64_t exception_osarray_cache = 0;
uint64_t get_exception_osarray(void) {
    if (exception_osarray_cache == 0) {
        exception_osarray_cache = OSUnserializeXML(
            "<array>"
            "<string>/Library/</string>"
            "<string>/private/var/mobile/Library/</string>"
            "<string>/private/var/mnt/</string>"
            "</array>"
        );
    }

    return exception_osarray_cache;
}

static const char *exc_key = "com.apple.security.exception.files.absolute-path.read-only";

void set_sandbox_extensions(uint64_t proc) {
    DEBUGLOG(false, "set_sandbox_extensions called for %llx", proc);
    uint64_t proc_ucred = rk64(proc + 0x100);
    uint64_t sandbox = rk64(rk64(proc_ucred + 0x78) + 0x8 + 0x8);
    DEBUGLOG(false, "sandbox: %llx", sandbox);
    
    if (sandbox == 0) {
        DEBUGLOG(false, "no sandbox, skipping (proc: %llx)", proc);
        return;
    }

    if (has_file_extension(sandbox, abs_path_exceptions[0])) {
        DEBUGLOG(false, "already has '%s', skipping", abs_path_exceptions[0]);
        return;
    }

    uint64_t ext = 0;
    const char** path = abs_path_exceptions;
    while (*path != NULL) {
        ext = extension_create_file(*path, ext);
        if (ext == 0) {
            DEBUGLOG(false, "extension_create_file(%s) failed, panic!", *path);
        }
        ++path;
    }
    
    if (ext != 0) {
        extension_add(ext, sandbox, exc_key);
    }
}

void set_amfi_entitlements(uint64_t proc) {
    uint64_t proc_ucred = rk64(proc + 0x100);
    uint64_t amfi_entitlements = rk64(rk64(proc_ucred + 0x78) + 0x8);

    int rv = 0;
    
    rv = OSDictionary_SetItem(amfi_entitlements, "get-task-allow", offset_osboolean_true);
    if (rv != 1) {
        DEBUGLOG(false, "failed to set get-task-allow within amfi_entitlements!");;
    }
    
    rv = OSDictionary_SetItem(amfi_entitlements, "com.apple.private.skip-library-validation", offset_osboolean_true);
    if (rv != 1) {
        DEBUGLOG(false, "failed to set com.apple.private.skip-library-validation within amfi_entitlements!");
    }
    
    uint64_t present = OSDictionary_GetItem(amfi_entitlements, exc_key);

    if (present == 0) {
        rv = OSDictionary_SetItem(amfi_entitlements, exc_key, get_exception_osarray());
    } else if (present != get_exception_osarray()) {
        unsigned int itemCount = OSArray_ItemCount(present);
        DEBUGLOG(false, "got item count: %d", itemCount);

        BOOL foundEntitlements = NO;

        uint64_t itemBuffer = OSArray_ItemBuffer(present);

        for (int i = 0; i < itemCount; i++) {
            uint64_t item = rk64(itemBuffer + (i * sizeof(void *)));
            char *entitlementString = OSString_CopyString(item);
            DEBUGLOG(false, "found ent string: %s", entitlementString);
            if (strcmp(entitlementString, "/Library/") == 0) {
                foundEntitlements = YES;
                free(entitlementString);
                break;
            }
            free(entitlementString);
        }

        if (!foundEntitlements){
            rv = OSArray_Merge(present, get_exception_osarray());
        } else {
            rv = 1;
        }
    } else {
        rv = 1;
    }

    if (rv != 1) {
        DEBUGLOG(false, "Setting exc FAILED! amfi_entitlements: 0x%llx present: 0x%llx\n", amfi_entitlements, present);
    }
}

void platformize(int pd) {
    uint64_t proc = proc_find(pd);
    if (proc == 0) {
        DEBUGLOG(true, "failed to find proc for pid %d!", pd);
        return;
    }
    
    DEBUGLOG(true, "platformize called for %d (proc: %llx)", pd, proc);
    
    set_csflags(proc);
    set_amfi_entitlements(proc);
    set_sandbox_extensions(proc);
    set_csblob(proc);
}
