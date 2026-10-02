package org.questcraft.veq.client.input;

import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.ClipContext;

/** Item-aware fluid policy for controller-ray target snapshots. */
final class HandRaycastFluidPolicy {
    private HandRaycastFluidPolicy() {
    }

    static ClipContext.Fluid forUse(ItemStack stack) {
        return switch (classify(stack.is(Items.BUCKET))) {
            case SOURCE_ONLY -> ClipContext.Fluid.SOURCE_ONLY;
            case NONE -> ClipContext.Fluid.NONE;
        };
    }

    static FluidProfile classify(boolean emptyBucket) {
        // Matches BucketItem's empty-bucket source lookup. Filled buckets and
        // ordinary block interactions must retain the normal non-fluid target.
        return emptyBucket ? FluidProfile.SOURCE_ONLY : FluidProfile.NONE;
    }

    enum FluidProfile {
        NONE,
        SOURCE_ONLY
    }
}
